# P&R pipeline reference

What actually runs, end to end, for the CI P&R lane (`docs/infra-plan.md`
Phase 5; `openspec/changes/ci-pnr-lane`). Two levels: the GitHub Actions
workflow that owns the VM and the artifacts, and the 9-stage OpenROAD flow
that workflow invokes on it.

## CI workflow level (`.github/workflows/pnr.yml`)

| Job | Runs on | What it does |
|---|---|---|
| `start` | `ubuntu-latest` | OIDC login to Azure, starts the self-hosted VM (idempotent — no-op if already running). |
| `pnr` | self-hosted VM | Checks out the repo, generates the hardware config, pickles RTL, runs `make synth-all` then `make -C target/ihp13/openroad run-pnr` (the 9-stage flow below), builds a stage-status summary from `pnr_status.log`, uploads the final DEF and the reports/logs as workflow artifacts. |
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
| 6 | `grt` | `grt` | **Gate — the actual gate** (`PNR_GATE` default) | Global route: `global_route -congestion_iterations 20 -allow_congestion -verbose`. This is the stage the whole flow is judged on — `run_pnr.sh` exits non-zero if this fails, regardless of the best-effort stages after it. The long pole by far: single-threaded, congestion-bound at ~63–65% utilization, ~7h of initial routing before the congestion "extra iteration" loop even starts, then ~15min/iteration (measured via `-verbose`'s `GRT-0102` lines) — `-congestion_iterations` was cut from `chip.tcl`'s original 80 (a ~27h+ total run) down to 20 (~11–13h) once that per-iteration cost was actually measured. |
| 7 | `grt_repair` | `grt_repaired` | Best-effort | Post-route timing repair using global-route-based parasitics: buffer insertion, incremental global route, `repair_timing -repair_tns 20 -max_buffer_percent 15` (bounded down from chip.tcl's original 100 — that looped effectively forever on this design). `PNR_SKIP_GRT_REPAIR=1` skips the work but still re-saves the checkpoint under the uniform name `drt.tcl` expects. |
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
