## Why

The P&R lane has not reached global route on `main` since the yosys v0.69 upgrade (Phase 12) and
the Cheshire v0.3.1 bump. The 09-19 run timed out in `cts`, and the 09-26 run timed out in `dpl`
(its 2 h limit). In both, the negotiation legalizer starts from 2.5× more illegal cells than the
last good run (203,229 vs 82,811). The SHA-3 coprocessor's P&R measurement
(`sha3-cvxif-coprocessor` task 5.4) cannot run until the lane reaches `grt` again: it needs a
clean pre-coprocessor P&R reference on `main` to be measured against.

This change first assumed that the cause was the `gpl` density target (0.65) sitting below the
design's utilization. It raised the target to 0.72. Run `37037836332` disproved that: `dpl` timed
out again, from 223,074 illegal cells. The logs of all four runs on record show the actual
mechanism, in `gpl`'s second, timing-driven pass:

1. Routability mode inflates the target density, then reverts the inflation itself (`GPL-0055`).
2. The second timing-driven iteration runs a real `repair_design` while the placement is still
   at overflow ≈ 0.2. It adds 0.9–1.2 mm² of buffers (+5–7 %), and the target density jumps:
   to 0.90 in the good run, to 0.99 and 1.04 in the failed ones.
3. Nesterov diverges, `gpl` reverts to a snapshot (`GPL-0999`, overflow 0.19–0.22), and `dpl`
   inherits an unconverged placement.

The `-density` value only sets where this starts, so a higher value makes the jump bigger
(`docs/infra-plan.md` Phase 11, corrected 2026-10-03).

The change keeps its name, `raise-gpl-density-target`, for the branch and PR (#57) it already
has. Its content is now the revised plan below.

## What Changes

- Make `gpl` pass 2's timing-driven iterations virtual
  (`global_placement -keep_resize_below_overflow 0`). They still re-weight nets for timing, but
  they insert no buffers into a half-spread placement. The real `repair_design` and
  `repair_timing` between the two passes are unchanged. The value lives in
  `scripts/pnr/common.tcl` (`pnr_gpl_keep_resize`). `PNR_GPL_KEEP_RESIZE` and a `pnr.yml`
  input, `gpl_keep_resize`, override it, and `1.0` restores OpenROAD's default.
- Return the starting density to 0.65 (`pnr_gpl_density`, kept overridable).
- Make the die scalable (design D5, added 2026-10-03): `pnr_die_scale` (`PNR_DIE_SCALE`,
  `pnr.yml` input `die_scale`) scales the core's width and height. The default is 1.0, the
  taped-out die, which reached `grt` with D1 alone. 1.10 (+21 % core area, utilization ~55 %)
  is the fallback for a netlist that stops legalizing in time; its P&R figures are then for that
  floorplan, and the with/without-coprocessor comparison uses the same one.
- Raise the `dpl` and `cts` stage timeouts (2 h → 4 h, 4 h → 8 h) as a safety net. A timeout does
  not change what a stage computes, so a run still shows whether the old limits would have held.
- Replace the post-`dpl` density-headroom warning, whose premise was wrong, with a placement
  report. It covers whether `gpl` pass 2 reverted after a divergence, the final placement-area
  inflation, `dpl`'s utilization, and the illegal cells the legalizer starts from. A pass-2
  revert is a named warning, never a failure.
- Measure on one run with `stop_after=grt`, against run `34938462965`: `gpl` convergence,
  illegal cells, `dpl`/`cts` runtimes, HPWL, `grt` congestion (demand and Metal3) and WNS. If it
  reaches `grt`, the result is the clean pre-coprocessor reference on `main`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pnr-flow`: a new requirement that the run reports how global placement ended (converged, or
  reverted after a divergence) together with the illegal-cell count detailed placement starts
  from, so that an unconverged placement is named in the run's output, not discovered as a
  legalizer timeout.

## Impact

- **Code**: `target/ihp13/openroad/scripts/pnr/common.tcl` (`pnr_gpl_density` 0.65,
  `pnr_gpl_keep_resize` 0); `scripts/pnr/gpl.tcl` (pass 2 option, report lines);
  `scripts/chip.tcl` (same values); `run_pnr.sh` (timeouts, placement report);
  `.github/workflows/pnr.yml` (`gpl_keep_resize` and `die_scale` inputs);
  `scripts/floorplan_ring_2way.tcl` and `floorplan_ring_4way.tcl` (die scale, D5).
- **Results**: placement, CTS and routing all move, so P&R figures from before this change are
  not comparable with figures from after it. The SHA-3 change's task 5.4 is measured against
  the reference this change produces, on the same settings.
- **Risk**: with fewer buffers inserted during placement, setup timing after `gpl` may be worse.
  `cts`'s `repair_timing` still runs, and the lane skips `grt_repair`. WNS is measured, not
  gated. A better-converged placement can also move congestion into `grt`, which is why the run
  stops after `grt`, not `cts`.
- **Cost**: one P&R lane run, ≈ 12–30 h depending on how far it gets. It is dispatched only after
  the user approves it.
- **Not changed**: synthesis, the netlist, the pad ring and macro arrangement, the routability settings,
  the repair between the `gpl` passes, routing-layer adjustments, and the `grt` gate.
