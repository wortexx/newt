# P&R pipeline reference

What actually runs, end to end, for the CI P&R lane (`docs/infra-plan.md`
Phase 5; `openspec/changes/ci-pnr-lane`). Two levels: the GitHub Actions
workflow that owns the VM and the artifacts, and the 9-stage OpenROAD flow
that workflow invokes on it.

## CI workflow level (`.github/workflows/pnr.yml`)

| Job | Runs on | What it does |
|---|---|---|
| `start` | `ubuntu-latest` | OIDC login to Azure, starts the self-hosted VM (idempotent — no-op if already running). |
| `pnr` | self-hosted VM | Checks out the repo, generates the hardware config, pickles RTL, runs `make synth-all` (cached — see below) then `make -C target/ihp13/openroad -f openroad.mk run-pnr PROJ_NAME=basilisk` (the 9-stage flow below), builds a stage-status summary from `pnr_status.log`, uploads the final DEF and the reports/logs as workflow artifacts. |
| `upload-checkpoints` | self-hosted VM | Pushes `.zip` checkpoints to the `pnr-checkpoints` blob container (task 1.3) so a later run can resume without redoing synth+P&R from scratch. |
| `stop` | `ubuntu-latest` | Checks whether the runner is still needed (busy, or another `pnr.yml`/`synth.yml` run queued) before deallocating the VM — the coexistence guard. |

Triggers: `schedule`, `workflow_dispatch`, `push`; no `pull_request` (P&R is
too slow/expensive to run on every PR). `concurrency: group: pnr,
cancel-in-progress: false` prevents two `pnr.yml` runs from fighting over
the same VM; it does **not** protect against manual out-of-band work on the
same workspace (a real, sharp edge — see the Notes section).

`vm-watchdog.yml` runs hourly and deallocates the VM if it's sat idle,
independent of this workflow — the backstop for a `stop` job that never ran.

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
| 1 | `floorplan` | `power_grid` | **Gate** | Reads the synthesized netlist, links the design, reads SDC, runs `check_setup`/`report_checks` sanity checks, creates the floorplan (ring layout, 2-way or 4-way L1 cache depending on `L1CACHE_WAYS`), then builds the power grid (stripes/rings). Only stage that reads the netlist directly — everything after loads a checkpoint. |
| 2 | `pre_place` | `pre_place` | **Gate** | Repairs tie-cell fanout, then `remove_buffers`. Deliberately its own tiny stage: `remove_buffers` is known to segfault roughly 1 run in 3, and isolating it means a retry only redoes this cheap step, not floorplan/power-grid. The only stage with a configured retry (1). |
| 3 | `gpl` | `gpl2` | **Gate** | Global placement, two passes. Pass 1 (routability-driven) gives rough parasitics; `repair_design`/`repair_timing -repair_tns 70` clean up setup violations on that rough placement; pass 2 (routability + timing-driven) is the placement that actually carries forward. Only stage besides `drt` that calls `set_thread_count` (up to 32 threads, capped by the VM's core count). |
| 4 | `dpl` | `dpl` | **Gate** | Detailed (legalized) placement + mirror optimization. Single-threaded. |
| 5 | `cts` | `cts` | **Gate** | Clock tree synthesis. Lifts clock dont-touch (only stage that does — clock nets are protected everywhere else), repairs clock inverters and post-CTS wire length, legalizes, then `repair_timing -setup -repair_tns 90` to fix the setup violations CTS itself introduces. `check_placement` is caught/non-fatal here (thousands of buffer-overlap warnings after repair are diagnostic-only, don't block progress). |
| 6 | `grt` | `grt` | **Gate — the actual gate** (`PNR_GATE` default) | Global route: `global_route -congestion_iterations 14 -allow_congestion -verbose`. This is the stage the whole flow is judged on — `run_pnr.sh` exits non-zero if this fails, regardless of the best-effort stages after it. The long pole by far: single-threaded, congestion-bound at ~63–65% utilization. `-congestion_iterations` was cut from `chip.tcl`'s original 80, to 20, to 14 across three real timeout failures — the last cut wasn't about average per-iteration cost but a specific finding: iterations 1–14 complete trivially, then iteration 15 itself triggers a clock-net NDR-relaxation cascade with no observed sign of ever terminating (10+ hours, no completion). See Notes. |
| 7 | `grt_repair` | `grt_repaired` | Best-effort | Post-route timing repair using global-route-based parasitics: buffer insertion, incremental global route, `repair_timing -repair_tns 20 -max_buffer_percent 15` (bounded down from chip.tcl's original 100 — that looped effectively forever on this design). `PNR_SKIP_GRT_REPAIR=1` skips the work but still re-saves the checkpoint under the uniform name `drt.tcl` expects. **Currently skipped in `pnr.yml`** — even with its `global_route` calls bounded the same way `grt.tcl`'s are, real data (`pnr-bringup-6`) shows it still doesn't converge within 16h (see Notes); skipping lets `drt`/`final` actually run and produce a DEF while grt_repair's own timeout/tuning is revisited separately. |
| 8 | `drt` | `drt` | Best-effort | Antenna repair, then detailed routing (`detailed_route`, multi-threaded like `gpl`). `-droute_end_iter` (default 40, override via `PNR_DRT_END_ITER`) bounds the iteration budget — a manual run needed stopping after 700k→516k DRC violations over 2 iterations without converging, so this is deliberately capped rather than left open-ended. |
| 9 | `final` | `final` | Best-effort | Filler cell placement, a non-fatal `check_placement`, then writes `out/<proj>.final.def` — the artifact the workflow uploads. |

**Gate vs. best-effort**: stages 1–6 (`floorplan` through `grt`) must all
succeed for `run_pnr.sh` to exit 0; `PNR_GATE` controls exactly where that
line is (default `grt`, per `specs/pnr-flow`: "success is gated through
global route"). Stages 7–9 run regardless and record their outcome in
`pnr_status.log`, but never flip the overall exit code — a bad
`grt_repair`/`drt`/`final` doesn't fail CI. This matches the project's
accepted reality that clean routing on this design is a stretch goal, not a
requirement.

**Per-stage timeouts** (`run_pnr.sh`, override via `PNR_TIMEOUT_<STAGE>` or
blanket `PNR_STAGE_TIMEOUT`): `floorplan` 1h, `pre_place` 30m, `gpl` 4h,
`dpl` 2h, `cts` 4h, `grt` 4h (in practice needed 8h+ — see Notes),
`grt_repair` 6h, `drt` 16h, `final` 1h.

## Notes from real bring-up (task 2.4)

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
- `synth-all` (~3h on this design) is cached in `pnr.yml`, keyed on
  `pickle-all`'s already-flattened single-file RTL output
  (`target/ihp13/pickle/out/*.sv2v.v`) plus the yosys synthesis scripts —
  added after three P&R-only-bug retries in a row each re-paid that ~3h
  for byte-identical output. A genuinely different commit's RTL/scripts
  still misses and resynthesizes.
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
