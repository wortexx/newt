# Design

## Context

See proposal.md for why. What the flow does today:

- **Detailed-routing settings are fixed.** `pnr.yml` hard-codes `PNR_DRT_END_ITER=5`, `PNR_TIMEOUT_DRT=86400` and `PNR_SKIP_ANTENNA_REPAIR=1` in the `pnr` step's environment. `drt.tcl` already reads both variables, and its own defaults are 40 iterations and antenna repair on. The job's ceiling is 48 h (`timeout-minutes: 2880`), and a full run reaches `drt` in about 6 h.
- **Antenna repair was skipped because it hung.** In run `34389061373` (pnr-bringup-7), the layout was at 101 % global-route demand. `repair_antennas` inserted 47,980 diodes, their legalization did not converge, and the incremental re-route hung for about 14 h. It has never been run on a legal, less congested layout.
- **The status line counts the wrong thing.** `drt.tcl` counts `violation type` lines in `basilisk_route_drc.rpt` and reports them as `drc_report_lines`. OpenROAD caps that file at 10,000 markers per violation type. Run `38473439796` lists 21,110 entries (10,000 shorts, 10,000 metal-spacing, plus the smaller types), while the router logged `DRT-0199 Number of violations = 715558`. The router's own per-iteration count (`DRT-0199`) and its per-layer table (`Viol/Layer`) are in `pnr_drt.log`.
- **Post-stage reports parse the stage logs.** `run_pnr.sh` already does this after `dpl` (`report_placement_state`) and `grt` (nets outside the core).
- **Where routing stands** (probe B layout: die scale 1.10, `gpl` density 0.65, inflation 2.5, margins blocked):

  | iteration | 0 | 1 | 2 | 3 | 4 | 5 |
  |---|---:|---:|---:|---:|---:|---:|
  | violations | 1,928,860 | 1,314,060 | 1,247,623 | 847,112 | 751,136 | 715,558 |

  - Iteration 5 by layer: shorts M2 255,786, M3 110,839, M4 130,361, M5 118,314; metal spacing M2 61,644.
  - Wire: M2 31.7 M, M3 27.8 M, M4 40.4 M, M5 28.7 M, TopMetal1 0.8 M µm; TopMetal2 is power-only.
  - `grt`: 59.7 % demand, 74,776 overflowing edges. `DPL-0009` utilization 56.3 %.

## Goals / Non-Goals

**Goals:**

- Find die-scale and placement-density settings under which detailed routing converges to 0 violations within the lane's budget, with antenna repair.
- Report the router's real violation counts on every run, so probes can be compared without reading raw logs.

**Non-Goals:**

- Timing closure. WNS is reported as is, and a larger die will make it worse.
- Signoff (KLayout DRC, LVS).
- Re-running the reference and both-arms thesis comparison: a follow-up change.
- Changing the flow's default die scale or density. That happens only if the user adopts a probe's settings, and then as its own task with a measured run.

## Decisions

### D1. Two dispatch inputs, empty = today

- `drt_end_iter` sets `PNR_DRT_END_ITER`. Empty keeps 5.
- `antenna_repair` set to `1` sets `PNR_SKIP_ANTENNA_REPAIR=0`. Empty keeps the skip.

This is the same pattern as `skip_grt_repair`. Scheduled runs keep exactly today's environment. `PNR_TIMEOUT_DRT` stays 24 h. A converging route should finish well inside it, and a run that doesn't converge is answered by the probe data, not by more time.

*Alternative rejected:* a free-form environment-override input. It is more general, but it lets a dispatch change anything without the spec saying what.

### D2. The router's counts come from the stage log

A `report_drt_outcome` step in `run_pnr.sh`, following the `report_placement_state` pattern, runs after `drt`. From `pnr_drt.log` it reads:

- every `DRT-0199 Number of violations = N` line, one per iteration;
- the last `Viol/Layer` table.

It writes them to `reports/basilisk.drt.violations.txt`, appends a `drt-violations final=<N> iterations=<k> trajectory=<n0,n1,…>` line to `pnr_status.log`, and adds them to the step summary.

`drt.tcl` drops the report-file count and stops writing `drc_report_lines`. The report file stays, for its locations.

*Alternative rejected:* counting the router's markers through the database API inside `drt.tcl`. That ties the count to an OpenROAD API surface. The log lines are what the run already prints and what every finding so far was read from.

### D3. The probe metric is the violation count after iterations 0 and 1

Each probe runs `stop_after=drt`, `drt_end_iter=1` (iterations 0 and 1, about 3.5 h on the current layout, less on a sparser one) and the default inputs otherwise. `final` does not run. It is a full run from the synth cache: floorplan through `grt` about 6 h, so about 9–10 h and about $11 per probe.

Thresholds:

- **Go to Phase 2:** iteration-0 violations ≤ 10 % of probe B's (≤ 193 k).
- **Promising enough to route to convergence:** ≤ 50 k after iteration 1. At that level, later iterations take minutes.

Global-route overflow is recorded but not used to decide. On this design it has been about 10× more optimistic than detailed routing, though it moves in the same direction.

### D4. Probe matrix, adaptive, starting in the middle

Utilization scales with the core area: ≈ 56.3 % × (1.10 / s)².

| probe | die scale | core util. | `gpl` density | question |
|---|---:|---:|---:|---|
| P2 (first) | 1.25 | ≈ 43.6 % | 0.50 | does real spreading collapse the violations? |
| P3 | 1.40 | ≈ 34.8 % | 0.45 | what does much more room buy? (run only if P2 misses the go threshold) |
| P1 | 1.10 | 56.3 % | 0.60 | is density alone enough, at today's die? (run only if P2 passes, to see whether the die needs to grow) |

The density stays a few points above utilization, because routability inflation (2.5) adds about 34 % area during `gpl` (`GPL-1014` on probe B) and needs room to grow into. 0.58 at 56 % would leave none, so P1 uses 0.60.

Running adaptively means two probes in the likely case and three at most.

*Alternative rejected:* a full grid (3 die scales × 3 densities). Nine runs cost about $100 and 4 days, and the first two answers already decide which way to go.

### D5. Phase 2 routes the best probe to convergence

Dispatch the winning settings with `drt_end_iter=64` (OpenROAD's default budget) and `antenna_repair=1`, without `stop_after`, so `final` writes the DEF. Success: the router reports a final total of 0.

If antenna repair hangs again, as it did at 101 % demand, re-dispatch from the `grt` checkpoint without it. That separates the routing result from antenna. Antenna then becomes its own lever, for example `repair_antennas -jumper_only`, which `drt.tcl` already names.

### D6. Phase 3 is a decision, not a plan

If the best probe does not converge, the next levers are:

- cell padding, for Metal2 pin access;
- more signal capacity on TopMetal1/TopMetal2;
- a lower `kperm` rounds-per-cycle. It is the current critical path, it appears in the DRC sample, and it is a design change.

The user chooses with the probe data in hand. Each needs a small flow or RTL edit and its own measured run, scoped then.

## Risks / Trade-offs

- **[Die scales above 1.10 are untested.]** Macro placement and the power grid scale with the core in `floorplan_ring_*way.tcl`, but nothing has run at 1.25 or 1.40. → A floorplan or PDN failure shows within minutes of the run. Fix it, or fall back to the next scale.
- **[Lower density can make `gpl` diverge.]** It did at 0.72 for different reasons (`raise-gpl-density-target`). → Every probe's placement report already says whether `gpl` converged or reverted. A diverged probe counts as a failed setting, not as data about routing.
- **[A sparser layout routes longer wires.]** WNS gets worse and the clock tree grows (seen on the reference). → Accepted for this goal. Timing is reported, not gated.
- **[Antenna repair may hang again.]** → D5's fallback separates it from the routing result.
- **[Probes run one after another on the one VM, and the nightly synth cron competes for it.]** → Dispatch each with the user's approval, and cancel or accept the queued cron as decided at that time.
- **[A per-run comparison is noisy.]** Placement varies run to run. → The thresholds are an order of magnitude apart, far above run-to-run variation. Close calls get a second run before any decision.
