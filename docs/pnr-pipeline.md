# P&R pipeline reference

What actually runs, end to end, for the CI P&R lane (`docs/infra-plan.md`
Phase 5; `openspec/changes/ci-pnr-lane`). Two levels: the GitHub Actions
workflow that owns the VM and the artifacts, and the 9-stage OpenROAD flow
that workflow invokes on it.

## CI workflow level (`.github/workflows/pnr.yml`)

| Job | Runs on | What it does |
|---|---|---|
| `start` | `ubuntu-latest` | OIDC login to Azure, starts the self-hosted VM (idempotent — no-op if already running). |
| `restore-checkpoints` | self-hosted VM (no container) | Only does work when `PNR_RESUME_FROM_RUN` (repository variable) or the `resume_from_run` dispatch input names a previous run: downloads that run's checkpoints from Blob into `/home/newt/pnr-restore/<run_id>` — outside the workspace, which `actions/checkout` would `git clean -ffdx`. The `pnr` job's own restore step then honors the `resume_exclude` dispatch input to leave named checkpoints out, so their stages run again. Runs outside the job container because az CLI lives on the VM host, and design D8 gives the `pnr` job no Azure access. |
| `pnr` | self-hosted VM | Checks out the repo, generates the hardware config, pickles RTL, runs `make synth-all` (cached — see below) then `make -C target/ihp13/openroad -f openroad.mk run-pnr PROJ_NAME=basilisk` (the 9-stage flow below), then moves the stage checkpoints and `synth-key.txt` out of the workspace into `/home/newt/pnr-export/<run_id>` (the export step — see the collision note below), builds a stage-status summary from `pnr_status.log`, uploads the final DEF and the reports/logs as workflow artifacts. |
| `upload-checkpoints` | self-hosted VM | Pushes `.zip` checkpoints from `/home/newt/pnr-export/<run_id>` — never from the workspace — to the `pnr-checkpoints` blob container (task 1.3) so a later run can resume without redoing synth+P&R from scratch, then removes that directory. Fails loudly when the `pnr` job succeeded but left no checkpoint to upload; a `pnr` job that failed before its first checkpoint, or never reached the export step, is reported and passed over. |
| `stop` | `ubuntu-latest` | Checks whether the runner is still needed (busy, or another `pnr.yml`/`synth.yml` run queued) before deallocating the VM — the coexistence guard. |

Triggers: `schedule`, `workflow_dispatch`, `push`; no `pull_request` (P&R is
too slow/expensive to run on every PR). `concurrency: group: pnr,
cancel-in-progress: false` prevents two `pnr.yml` runs from fighting over
the same VM. It says nothing about the workspace the two lanes share, and
neither does the `stop` guard — but the lanes' own automated runs can no
longer hurt each other there, because the `pnr` job hands its checkpoints to
`/home/newt/pnr-export/<run_id>` before it releases the runner, so a
`synth.yml` (or any other) checkout that lands between `pnr` and
`upload-checkpoints` has nothing of this run's to clean. Manual out-of-band
work on the same workspace is the remaining sharp edge (a real one — see the
Notes section).

`vm-watchdog.yml` runs hourly and deallocates the VM if it's sat idle,
independent of this workflow — the backstop for a `stop` job that never ran.

### Manual dispatch inputs

`workflow_dispatch` accepts thirteen optional inputs, all empty by default
(`resume_from_run`, `resume_exclude`, `stop_after`, `gpl_density`,
`gpl_keep_resize`, `die_scale`, `dpl_legalizer`, `dpl_max_displacement`,
`skip_grt_repair`, `drt_end_iter`, `antenna_repair`, `grt_metal2_adjust`, `cell_pad_sites` — matching `pnr.yml`'s
`inputs:` keys exactly). With all of them empty, a dispatched run
behaves exactly like a scheduled run:

- `resume_from_run` — a previous run's ID whose checkpoints to restore
  before P&R starts (feeds `restore-checkpoints`, above). The `pnr` job's
  restore step refuses to resume if those checkpoints were built from a
  different netlist than the dispatched ref produces (the synth-key
  identity guard).
- `resume_exclude` — space-separated checkpoint base names (no project
  prefix, no `.zip`) to leave out of that restore, so their stages run
  again. Feeds `PNR_RESUME_EXCLUDE`.
- `stop_after` — a stage name (see the stage table below) after which the
  driver stops rather than continuing through `final`. Feeds
  `PNR_STOP_AFTER`. Does not change the gate (`PNR_GATE`, fixed at `grt`
  and not exposed as an input): a dispatch that stops before the gate
  still exits non-zero.
- `gpl_density` — the global-placement starting target density for both
  `gpl` passes, e.g. `0.70`. Feeds `PNR_GPL_DENSITY`. Empty means
  `pnr_gpl_density`'s default in `scripts/pnr/common.tcl` (0.65).
- `gpl_keep_resize` — `gpl` pass 2's `-keep_resize_below_overflow`. Feeds
  `PNR_GPL_KEEP_RESIZE`. Empty means `pnr_gpl_keep_resize`'s default in
  `common.tcl` (0: the timing-driven iterations are virtual); `1.0` is
  OpenROAD's default and restores the flow before this setting.

- `die_scale` — the core's width and height relative to the taped-out
  Basilisk die. Feeds `PNR_DIE_SCALE`. Empty means `pnr_die_scale`'s default
  in `common.tcl`, `1.10`: a 6777 × 5950 µm die (+21 % core area), the default
  since `use-diamond-legalizer` because the SoC with both SHA-3 arms cannot
  be legalized after `cts` on the taped-out die. `1.0` is the taped-out
  6230 × 5478 µm die. Lane figures are for the enlarged die, so compare runs
  only at the same setting. Changing it invalidates every checkpoint from
  `floorplan` on, so do not combine it with `resume_from_run`.

- `dpl_legalizer` — the legalizer every `detailed_placement` call uses
  (`dpl`, both `cts` passes, `grt_repair`). Feeds `PNR_DPL_LEGALIZER`. Empty
  means `pnr_dpl_legalizer`'s default in `common.tcl` (`diamond`, OpenROAD's
  classic legalizer, which places every cell or fails); `negotiation` is
  OpenROAD's own default, which left 10–13 k overlapping cells in every run
  before `use-diamond-legalizer`. Any other value fails the stage. Either way
  `dpl` and `cts` end with a gated legality check. Changing it invalidates
  the `dpl` checkpoint and everything after it, so with `resume_from_run`
  also exclude `dpl cts grt grt_repaired`.

- `dpl_max_displacement` — the legalizer's search window, passed to every
  `detailed_placement` call as `-max_displacement`, in microns: one value
  for both directions or `x y`. Feeds `PNR_DPL_MAX_DISPLACEMENT`. Empty means
  `pnr_dpl_max_displacement`'s default in `common.tcl`, `1000 1000`
  (±2083 sites, ±264 rows); `openroad` keeps OpenROAD's own window (±500
  sites, ±100 rows here), which left 3,719 cells unplaced in `cts` at 71.3 %
  utilization (run 38071835792). Each stage log's `DPL-0005` line records
  the window used. Like `dpl_legalizer`, it invalidates the checkpoints of
  every stage that legalizes.

- `skip_grt_repair` — whether to skip post-route timing repair. Feeds
  `PNR_SKIP_GRT_REPAIR`. Empty means `1`, the default on every scheduled and
  tag run: `grt_repair` only re-saves the `grt` checkpoint as
  `grt_repaired`. `0` runs `grt_repair.tcl`'s bounded repair (see the stage
  table). It stays best-effort either way: a failure or a timeout
  (`PNR_TIMEOUT_GRT_REPAIR`, 16h in `pnr.yml`) is logged in
  `pnr_status.log` and never changes the run's exit status.

- `drt_end_iter` — detailed routing's iteration budget,
  `detailed_route -droute_end_iter`. Feeds `PNR_DRT_END_ITER`. Empty means
  `5`, the budget on every scheduled and tag run; `64` is OpenROAD's own
  default, for routing to convergence (change `drc-clean-pnr`). The stage's
  24h timeout (`PNR_TIMEOUT_DRT`) is fixed and still applies, and `drt`
  stays best-effort. Its `pnr_status.log` line records the budget used.

- `antenna_repair` — whether to run `repair_antennas` before detailed
  routing. Feeds `PNR_SKIP_ANTENNA_REPAIR`. Empty means skip (`1`), as on
  every scheduled and tag run, since repair hung for about 14h at 101 %
  routing demand (run 34389061373, see `drt.tcl`); `1` runs it. Either way
  `drt` stays best-effort, and its `pnr_status.log` line says
  `antenna=repaired` or `antenna=skipped`.

- `grt_metal2_adjust` — the share of Metal2's capacity that global routing
  holds back (`set_global_routing_layer_adjustment Metal2`), in [0, 1).
  Feeds `PNR_GRT_METAL2_ADJUST`. Empty means `pnr_grt_metal2_adjust`'s
  default in `common.tcl`, `0.30`, chip.tcl's value; Metal3 stays at 0.30.
  A larger value moves global routes off Metal2, which held 84 % of the
  detailed-routing violations on probe P2 (change `drc-clean-pnr`, design
  D7). Every routing stage logs `Global routing layer adjustment:` with the
  values used. It invalidates the `grt` checkpoint and everything after it,
  so with `resume_from_run` also exclude `grt grt_repaired drt`.

- `cell_pad_sites` — free sites kept on each side of every standard cell.
  Feeds `PNR_CELL_PAD_SITES`. Empty means `pnr_cell_pad_sites`'s default in
  `common.tcl`, `0`, no padding. Both `gpl` passes plan for it
  (`-pad_left/-pad_right`), and every `detailed_placement` call (`dpl`,
  `cts`, `grt_repair`) keeps it (`set_placement_padding -global`), so the
  gated legality checks after `dpl` and `cts` also fail on padding
  violations. `final` clears it before filler placement. Each stage logs
  `Cell padding: <n> sites`. Meant to free Metal2 tracks for pin access
  (change `drc-clean-pnr`, design D8). One site adds about 22 % to the cell
  area. It invalidates the `gpl2` checkpoint and everything after it.

  The `gpl_*` inputs let a placement experiment run without a commit.
  Combined with `resume_from_run`, exclude `gpl` and every later checkpoint,
  or the restored placement is reused and the value has no effect.

Worked example — re-running just `grt_repair` against a previous full run's
checkpoints, stopping once it completes (design D1's "Run B"):

```console
$ gh workflow run pnr.yml \
    -f resume_from_run=<A> \
    -f resume_exclude=grt_repaired \
    -f stop_after=grt_repair
```

This restores run `<A>`'s checkpoints, skips every stage through `grt`
(all restored), excludes `grt_repaired` from the restore so `grt_repair`
itself runs again, and stops there — exercising one slice of the flow
against real data in minutes instead of the full ~26h run. With the
default `skip_grt_repair`, that slice only re-saves the checkpoint. To
measure the repair itself (change `bounded-grt-repair-measurement`), add
`-f skip_grt_repair=0`. The stage then takes hours, not minutes, up to its
16h timeout:

```console
$ gh workflow run pnr.yml --ref <branch whose netlist matches run A> \
    -f resume_from_run=<A> \
    -f resume_exclude=grt_repaired \
    -f stop_after=grt_repair \
    -f skip_grt_repair=0
```

## OpenROAD stage level (`target/ihp13/openroad/scripts/pnr/*.tcl`)

Architecture: one `openroad -exit` process per stage (not one long-lived
session like the original `chip.tcl`), driven by `run_pnr.sh`. Each stage
loads the previous stage's checkpoint (`save_checkpoint`/`load_checkpoint`,
a `.zip` of the physical database + netlist), does its work, and saves its
own checkpoint. This is what makes a mid-flow crash retryable (only the
dead stage reruns, not the whole flow) and a stopped run resumable (already-
checkpointed stages skip on restart). The cost: checkpoints don't carry SDC
constraints, dont-touch/dont-use sets, or routing-layer config — every stage
has to re-derive those itself via `common.tcl`'s `pnr_*` helper procs before
doing anything else.

| # | Stage | Checkpoint | Gate? | What it does |
|---|---|---|---|---|
| 1 | `floorplan` | `power_grid` | **Gate** | Reads the synthesized netlist, links the design, reads SDC, runs `check_setup`/`report_checks` sanity checks, creates the floorplan (ring layout, 2-way or 4-way L1 cache depending on `L1CACHE_WAYS`; die scaled by `pnr_die_scale`, default 1.10, see `die_scale` above), then blocks placement in every gap between a macro and the core edge no wider than `pnr_macro_margin_max` (`scripts/pnr/common.tcl`, default 20 µm; `PNR_MACRO_MARGIN_MAX`, `0` turns it off). The floorplan keeps macros 8 µm (east/west) or 14 µm (south/north) off the core edge, and without the blocking the placer filled those margins with logic the macros wall in (6,308 cells and 9,313 nets routed outside the core in run 38094932339; change `keep-cells-out-of-macro-margins`). The log lists every blockage (`Macro margin blocked: …`) and the total. Then it builds the power grid (stripes/rings). Only stage that reads the netlist directly — everything after loads a checkpoint. Changing `PNR_MACRO_MARGIN_MAX`, or resuming a run with this blocking from checkpoints made before it, mixes floorplans: the restore's synth-key guard does not catch it, because the netlist is the same, so do not combine either with `resume_from_run` across that boundary. |
| 2 | `pre_place` | `pre_place` | **Gate** | Repairs tie-cell fanout, then `remove_buffers`. Deliberately its own tiny stage: `remove_buffers` is known to segfault roughly 1 run in 3, and isolating it means a retry only redoes this cheap step, not floorplan/power-grid. The only stage with a configured retry (1). |
| 3 | `gpl` | `gpl2` | **Gate** | Global placement, two passes. Pass 1 (routability-driven) gives rough parasitics; `repair_design`/`repair_timing -repair_tns 70` clean up setup violations on that rough placement; pass 2 (routability + timing-driven) is the placement that actually carries forward. Both passes start from target density `pnr_gpl_density` (`scripts/pnr/common.tcl`, default 0.65; `PNR_GPL_DENSITY` / the `gpl_density` input override it). Pass 2's timing-driven iterations are virtual (`-keep_resize_below_overflow`, `pnr_gpl_keep_resize`, default 0; `PNR_GPL_KEEP_RESIZE` / the `gpl_keep_resize` input): they re-weight nets but insert no buffers. `gpl.tcl` logs both values. Both passes run routability mode with `-routability_inflation_ratio_coef 2.5 -routability_max_inflation_ratio 2.5`, so cells in congested regions are inflated enough to move; upstream's 1.2 added about 1 % area per routability iteration, and with the macro margins blocked it let the displaced cells pile into the SPI host corner and tripled `grt` overflow (change `keep-cells-out-of-macro-margins`, runs 38254112819 and 38395368038). Only stage besides `drt` that calls `set_thread_count` (up to 32 threads, capped by the VM's core count). |
| 4 | `dpl` | `dpl` | **Gate** | Detailed (legalized) placement + mirror optimization. Single-threaded. Legalizes with `pnr_dpl_legalizer` (`scripts/pnr/common.tcl`, default `diamond`, OpenROAD's classic legalizer; `PNR_DPL_LEGALIZER=negotiation` selects OpenROAD's default, which leaves cells overlapping on this design). Ends with a **gated** `check_placement`: any overlap, padding or blocked-layer violation fails the stage before its checkpoint is saved, with the counts in `pnr_status.log` and the markers in `basilisk_dpl_check_placement.rpt`. Afterwards `run_pnr.sh` reports how `gpl` ended (below). |
| 5 | `cts` | `cts` | **Gate** | Clock tree synthesis. Lifts clock dont-touch (only stage that does — clock nets are protected everywhere else), repairs clock inverters and post-CTS wire length, legalizes, then `repair_timing -setup -repair_tns 90` to fix the setup violations CTS itself introduces. Both legalizations use the same legalizer as `dpl`, and the stage ends with the same **gated** `check_placement` (`basilisk_cts_check_placement.rpt`). Until `use-diamond-legalizer` this check was caught and non-fatal, and 10–13 k overlapping cells reached `grt` in every run, until `drt` aborted on them (`DRT-0218`, run 37996272102). |
| 6 | `grt` | `grt` | **Gate — the actual gate** (`PNR_GATE` default) | Global route: `global_route -congestion_iterations 14 -allow_congestion -verbose`. This is the stage the whole flow is judged on — `run_pnr.sh` exits non-zero if this fails, regardless of the best-effort stages after it. The long pole by far: single-threaded, congestion-bound at ~63–65% utilization. `-congestion_iterations` was cut from `chip.tcl`'s original 80, to 20, to 14 across three real timeout failures — the last cut wasn't about average per-iteration cost but a specific finding: iterations 1–14 complete trivially, then iteration 15 itself triggers a clock-net NDR-relaxation cascade with no observed sign of ever terminating (10+ hours, no completion). See Notes. |
| 7 | `grt_repair` | `grt_repaired` | Best-effort | Post-route timing repair using global-route-based parasitics: buffer insertion, incremental global route, `repair_timing -repair_tns 20 -max_buffer_percent 15` (bounded down from chip.tcl's original 100 — that looped effectively forever on this design). `PNR_SKIP_GRT_REPAIR=1` skips the work but still re-saves the checkpoint under the uniform name `drt.tcl` expects. **Skipped by default in `pnr.yml`** (the `skip_grt_repair` input, empty = skip; `0` runs it) — even with its `global_route` calls bounded the same way `grt.tcl`'s are, real data (`pnr-bringup-6`, and again run `37512872714` on the post-2026-10-03 placement, where the incremental re-route after `repair_design` fell into the `GRT-0273` NDR-relaxation cascade; `docs/infra-plan.md` Phase 11) shows it still doesn't converge within 16h (see Notes); skipping lets `drt`/`final` actually run and produce a DEF while grt_repair's own timeout/tuning is revisited separately. |
| 8 | `drt` | `drt` | Best-effort | Bridges wrong-direction route guides first (`pnr_bridge_wrong_way_guides`, `PNR_BRIDGE_GUIDES=0` turns it off): every guide spanning more than one gcell against its layer's preferred direction is copied onto the adjacent preferred-direction layer, since detailed routing cannot traverse it and aborts with `DRT-0218` otherwise (change `bridge-wrong-way-route-guides`). Then antenna repair, then detailed routing (`detailed_route`, multi-threaded like `gpl`). `-droute_end_iter` (default 40, override via `PNR_DRT_END_ITER`; the lane uses 5) bounds the iteration budget — on the enlarged die each iteration takes about 3 h and violations barely fall after the second (3.12 M → 2.64 M → 2.58 M, run 38178131540), so this is deliberately capped rather than left open-ended. |
| 9 | `final` | `final` | Best-effort | Filler cell placement, a non-fatal `check_placement`, then writes `out/<proj>.final.def` — the artifact the workflow uploads. |

**Gate vs. best-effort**: stages 1–6 (`floorplan` through `grt`) must all
succeed for `run_pnr.sh` to exit 0; `PNR_GATE` controls exactly where that
line is (default `grt`, per `specs/pnr-flow`: "success is gated through
global route"). Stages 7–9 run regardless and record their outcome in
`pnr_status.log`, but never flip the overall exit code — a bad
`grt_repair`/`drt`/`final` doesn't fail CI. This matches the project's
accepted reality that clean routing on this design is a stretch goal, not a
requirement.

**Placement report** (`run_pnr.sh`, after `dpl`, whether `dpl` passed or
not). One line with what decides `dpl`'s legalization time: whether `gpl`'s
pass 2 reverted after a divergence (`GPL-0999`) and at what overflow; the
final placement-area inflation (`GPL-1014`); `dpl`'s utilization
(`DPL-0009`); the legalizer that ran (the `Legalizer:` line
`pnr_detailed_placement` logs); `dpl`'s legality check (passed, failed with
its violation counts, or no result when `dpl` did not finish); and, for the
negotiation legalizer, the illegal cells it starts from (its iteration-0 row;
the diamond legalizer logs no such count). `dpl` prints utilization,
legalizer and iteration-0 row before it legalizes, so they are there even
when the stage times out. When `gpl` was restored from a checkpoint, the `gpl` fields are left out and the `dpl` fields are still reported. A pass-2 revert emits a `::warning::`.
The report never changes the exit status (`specs/pnr-flow`). Why it exists:
in every run on record, pass 2 reverted at overflow ≈ 0.19–0.22, and `dpl`
started from 83 k to 223 k illegal cells, which timed it out at its old 2 h
limit (`docs/infra-plan.md` Phase 11).

The same line ends with two counts of cells that macros wall in, from
`dpl.tcl`'s `Macro margins:` and `Macro channels:` log lines (change
`keep-cells-out-of-macro-margins`): `macro margins: <n> cells (gap <= 20 um)`
and `macro channels: <n> cells (gap <= 40 um)`. The first counts cells
between a macro and the core edge, which the floorplan blocks, so it should
be 0; a non-zero count raises a `::warning::`. The second counts cells in
channels between two facing macros (`PNR_MACRO_CHANNEL_MAX`, default 40 µm),
which keep their rows and are only reported. Either is `not reported` when
`dpl` did not get that far. Both are logged before `dpl`'s legality check,
so a failed check still has them.

**Routes outside the core** (`run_pnr.sh`, after `grt`). One line,
`Nets routed outside the core: <n>`: the nets with at least one route-guide
rectangle whose centre lies outside the core area, counted from
`basilisk_route.guide` with the core area `grt.tcl` logs. Nets walled in
behind macros escape through the band between the core and the pads, which
has almost no routing capacity; run 38094932339 had 9,313 of them. It reads
only what the current `grt` run logged (`Route guides written:`), prints
`not computed (<reason>)` otherwise, takes about 15 s, and never changes the
exit status.

**Detailed-route violations** (`run_pnr.sh`, after `drt`, whatever its
outcome; change `drc-clean-pnr`). The router's own counts from
`pnr_drt.log`: every `DRT-0199 Number of violations = N` line (one per
iteration) and the `Viol/Layer` table after the last one (the final
iteration by type and layer). They go to `reports/basilisk.drt.violations.txt`
and to one `pnr_status.log` line,
`drt-violations final=<N> iterations=<k> trajectory=<n0,n1,…>`, or
`drt-violations none` when the router logged no count; the step summary
shows both. Never the DRC report file's entries: OpenROAD caps
`basilisk_route_drc.rpt` at 10,000 markers per violation type, so run
38473439796 listed 21,110 entries where the router counted 715,558. The
report never changes the exit status.

**Per-stage timeouts** (`run_pnr.sh`, override via `PNR_TIMEOUT_<STAGE>` or
blanket `PNR_STAGE_TIMEOUT`): `floorplan` 1h, `pre_place` 30m, `gpl` 4h,
`dpl` 4h, `cts` 8h, `grt` 4h (in practice needed 8h+ — see Notes),
`grt_repair` 6h, `drt` 16h (24h in `pnr.yml`, `PNR_TIMEOUT_DRT`, as margin over the
lane's 5 routing iterations of about 3h each), `final` 1h.

## Notes from real bring-up (task 2.4)

- **A sibling workflow's checkout destroyed a finished run's checkpoints
  (2026-09-15).** Run 34783899813 — Run A of `post-merge-ci-verification`,
  ~26h and ~$32 — finished its `pnr` job at 22:02:34Z with `grt ok`. The
  nightly `synth.yml` run 34820756433 was assigned the shared runner 2s
  later and its own `actions/checkout` ran `git clean -ffdx` at 22:02:40Z,
  6s after `pnr` ended, wiping the untracked
  `target/ihp13/openroad/save/`. `upload-checkpoints` did not get the runner
  until 00:31:40Z — 2.5h later, after the synth run finished — found an
  empty directory, printed "nothing to upload (pnr job may have failed
  before floorplan)" and exited 0. The `pnr` job had in fact succeeded; the
  run simply had no durable output, which only surfaced when a resume was
  attempted. Neither guard covered it: `concurrency: group: pnr` serializes
  `pnr.yml` runs against each other, and the `stop` guard only decides
  whether to power the VM off. **Fixed** by `pnr.yml`'s "Export checkpoints
  out of the shared workspace" step (change `pnr-checkpoints-outside-workspace`):
  the `pnr` job moves the checkpoints to `/home/newt/pnr-export/<run_id>`
  before it ends, mirroring what `restore-checkpoints` already did in the
  inbound direction, and `upload-checkpoints` reads only from there and now
  fails loudly rather than quietly if a successful flow left it nothing.
- Manual out-of-band work on the shared VM workspace (e.g. driving the flow
  directly via `docker exec` instead of through `pnr.yml`) has **no
  collision protection** — a real scheduled `synth.yml`/`pnr.yml` run's
  `actions/checkout` will `git clean` the workspace mid-run and silently
  destroy every checkpoint and report built up so far. `pnr.yml`'s
  concurrency guard only protects scheduled/dispatched runs against each
  other, not this case.
- `grt`'s `global_route` call started out unmodified from the original
  `chip.tcl` (`-congestion_iterations 80 -allow_congestion`) — the gap was
  that `chip.tcl`'s interactive session had no external timeout to race
  against, while the unattended flow's CI-safety timeout does. Two full
  timeout-killed attempts (4h, then 8h) later, `-verbose` finally gave real
  per-iteration timing (`GRT-0102 Start extra iteration N/80`, ~15min each,
  after ~7h of initial routing/NDR-disable work first) — extrapolated, 80
  iterations is a ~27h+ total run. Cut to `-congestion_iterations 20`
  (~11–13h total) as a result; `PNR_TIMEOUT_GRT` correspondingly raised to
  16h (`57600`) for margin.
- The first real `pnr.yml` run at `-congestion_iterations 20` (16h
  timeout) *still* timed out, and the real log data changed the diagnosis:
  iterations 1–14 all completed back-to-back with zero congestion-repair
  work logged (no `GRT-0273` lines at all), then iteration 15 itself
  triggered a cascade of "Disabled NDR" warnings across 63+ clock nets that
  never finished — "Start extra iteration 16/20" never appeared even after
  10+ hours inside iteration 15 alone. Not generic slowness a bigger
  timeout would fix — iteration 15 specifically (at whatever congestion
  state exists after 14 real rounds) hitting a relaxation cascade with no
  observed sign of terminating. Cut to `-congestion_iterations 14` to stop
  before ever entering it, rather than gambling more VM time on a step
  that never completed once.
- `pnr.yml`'s "Place and route" step had two real, previously-invisible
  bugs, each only surfacing on the first real end-to-end run (task 3.2):
  missing `-f openroad.mk` (there's no default `Makefile` in
  `target/ihp13/openroad/`, so this failed instantly with "No rule to make
  target 'run-pnr'") and missing `PROJ_NAME=basilisk` (the step bypasses
  the root `Makefile`/`iguana.mk` — the only place `PROJ_NAME` actually
  gets set to `basilisk` instead of `openroad.mk`'s bare `iguana_chip`
  default — so it looked for a netlist file that was never produced).
  `actionlint` can't catch either class of bug; both needed a real run to
  surface. Every manual bring-up invocation all through task 2.4 had both
  right; only the workflow step didn't.
- `synth-all` (~3h on this design) is cached in `pnr.yml` — added after
  three P&R-only-bug retries in a row each re-paid that ~3h for
  byte-identical output. **The original `actions/cache` implementation of
  this never produced a single hit** (found 2026-09-11, after eight runs),
  for two independent reasons: (1) Actions caches are scoped per ref, and
  because every bring-up run is triggered by a fresh tag — itself a
  workaround for `workflow_dispatch` not being registered until this
  branch merges — each run could only read caches written by its own tag
  or by the default branch, never by a sibling tag; (2) the key hashed
  *generated* pickle output, which isn't byte-reproducible (`pnr-bringup-6`
  → `-7` changed no RTL at all, yet the key moved). Both are fixed: the
  cache now lives on the VM's OS disk (mounted into the job container as
  `/synth-cache`, outside the git working tree that `actions/checkout`
  wipes, and on the disk that survives this lane's own deallocate cycle),
  and the key is a SHA-256 over `git rev-parse HEAD:<path>` tree hashes of
  every tracked input that can change the netlist (`Bender.{yml,lock}`,
  `hw/`, `target/ihp13/{yosys,pickle,pdk,src}`, `Makefile`, `iguana.mk`,
  `tools.mk`) plus the yosys version string. Git tree hashes are
  content-addressed, so the key is stable whenever the inputs are — it is
  identical across `pnr-bringup-4` through `-8`, every one of which paid
  full synthesis — and submodule pins come along for free, since a
  submodule appears in its parent tree as its commit SHA (this is what
  puts the PDK's liberty files in the key). The yosys version is included
  because the image tag (`:dev`) is mutable. Entries are marked
  `.complete` only after the copy finishes, so a run interrupted mid-write
  — this lane's known failure mode — can't be mistaken for a usable entry;
  the newest 5 are kept, and every cache write failure degrades to a
  warning rather than failing the run.
- `pnr-bringup-5` (run 34127033481) reached `grt ok` a second time (14/14
  iterations, clean) — confirmed only by reading `pnr_status.log` directly
  off the VM's disk — but the overall GitHub Actions job was still declared
  `failure`, ~10h after its last log line, with GitHub's own annotation:
  "the self-hosted runner lost communication with the server". Root cause:
  `run_pnr.sh`'s `run_stage_once` piped every stage's full stdout (already
  captured separately to `reports/pnr_<stage>.log` via openroad's own
  `-log`) a second time into the Actions job's *live* log stream via
  `gawk`. `grt.tcl`'s `-verbose global_route` dumped ~5,472 individual net
  names in under 50ms; the runner's live-streaming channel choked on that
  burst and the connection never came back, even though the underlying
  `openroad` process kept running fine and `grt` itself completed
  successfully hours later. **Fix**: `run_stage_once` now redirects the
  gawk-timestamped copy into `${logfile}.timestamped` (still uploaded via
  "Upload reports and logs", which already grabs the whole `reports/`
  directory) instead of mirroring it to stdout/the Actions log — every
  progress check this bring-up effort has done went through reading these
  `-log` files off the VM directly, never the Actions UI's live tail, so
  this costs no visibility and removes the failure mode outright.
- `pnr-bringup-6` (run 34224904566) is the **first `pnr.yml` run ever to
  complete with a clean GitHub Actions verdict** — `start`/`pnr`/
  `upload-checkpoints`/`stop` all `success`, no runner-communication-loss
  failure, confirming the fix above holds under the real ~27h workload it
  was built for (including `grt.tcl`'s own `-verbose` burst). But
  `pnr_status.log` tells the fuller story: `grt_repair failed exit=124
  attempts=1` — it hit its `PNR_TIMEOUT_GRT_REPAIR=57600` (16h) ceiling
  exactly, even with its `global_route` calls already bounded the same way
  as `grt.tcl`'s. `drt`/`final` were skipped as `predecessor-failed`, so no
  `out/basilisk.final.def` was produced — `run_pnr.sh` still exits 0
  (`grt_repair` is best-effort, design D4), so GitHub's `success` verdict
  doesn't mean a DEF exists. Root cause is structural, not a residual bug:
  `grt_repair.tcl` chains three route/repair phases (an incremental round,
  a full "GRT (2)" re-route comparable in cost to `grt.tcl`'s own ~9h pass,
  then another incremental round) — 2–3x `grt.tcl`'s own budget. Decision:
  rather than guess at a bigger timeout blind, `pnr.yml` now passes
  `PNR_SKIP_GRT_REPAIR=1` to get `drt`/`final` actually exercised and
  producing a real DEF off `grt`'s own checkpoint first; `grt_repair`'s own
  timeout/tuning is deliberately deferred until after that.
