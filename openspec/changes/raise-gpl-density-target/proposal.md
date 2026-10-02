## Why

The P&R lane has not reached global route on `main` since the yosys v0.69 upgrade (Phase 12) and
the Cheshire v0.3.1 bump. The 09-19 run timed out in `cts` and the 09-26 run timed out in `dpl`
(its 2 h limit). [`docs/infra-plan.md`](../../../docs/infra-plan.md) Phase 11 diagnosed the cause
on 2026-10-02. `gpl` places at `-density 0.65`, but the design's utilization entering `dpl` is
now 66.1 % (62.9 % before the upgrade). Global placement cannot spread cells below the density
the design needs, so the negotiation legalizer starts from 2.5× more illegal cells (203,229 vs
82,811). It grinds through them in `dpl` and again in `cts`, and HPWL after `cts` is 29 % worse.
The SHA-3 coprocessor (`sha3-cvxif-coprocessor`, +0.84 mm²) would push utilization to ~69.5 %,
so that change's P&R measurement (its task 5.4) cannot run until this is fixed. It needs a clean
pre-coprocessor P&R reference on `main` to be measured against.

## What Changes

- Raise the global-placement density target from `0.65` to about `0.72` in both passes
  (`GPL_ARGS`, `GPL2_ARGS`) of `target/ihp13/openroad/scripts/pnr/gpl.tcl`, the staged flow the
  P&R lane runs. The monolithic `scripts/chip.tcl` gets the same values, so the two stay
  consistent. The target must cover the coprocessor's ~69.5 % with margin; 0.72 is the starting
  value, and the measured utilization decides it.
- Make the margin visible. The `gpl` stage reports the density target next to the utilization
  `dpl` measures (`DPL-0009`), and the end-of-run summary flags a run whose utilization is at or
  above the target. A future netlist growth then surfaces as a named warning, not as a timeout
  hours later.
- Measure the effect against the last pre-upgrade run (`34938462965`) and the failed runs.
  Compare utilization, illegal cells at legalizer iteration 0, `dpl` and `cts` runtimes, HPWL,
  `grt` congestion (demand and Metal3) and WNS. Record the results in Phase 11.
- Produce the clean pre-coprocessor P&R reference on `main`: a run that reaches `grt` within the
  existing stage timeouts, with its stage, WNS and power recorded.
- Fallback, not a default: if denser placement makes `grt` congestion materially worse, raise
  only the `dpl`/`cts` timeouts (2 h → 4 h, 4 h → 8 h) and leave the density alone. That accepts
  the HPWL loss and is recorded as such.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pnr-flow`: a new requirement that the global-placement density target leaves headroom over
  the design's real utilization, and that the flow reports both, so that a design outgrowing the
  target is named in the run's output, not discovered as a legalizer timeout.

## Impact

- **Code**: `target/ihp13/openroad/scripts/pnr/gpl.tcl` (density values, report line);
  `target/ihp13/openroad/scripts/chip.tcl` (same values);
  `target/ihp13/openroad/run_pnr.sh` or the `pnr.yml` summary step (headroom warning).
  `run_pnr.sh`'s stage timeouts change only under the fallback.
- **Results**: placement, CTS and routing results all move, so every P&R figure from before this
  change is not comparable with one from after it. The SHA-3 change's P&R delta (task 5.4) is
  measured against the reference this change produces, on the same settings.
- **Risk**: higher placement density can worsen global-route congestion, which already blocks
  detailed routing (Phase 11: 101.17 % demand, Metal3 115.27 %). The success gate is `grt`, not
  `drt`, so detailed routing stays best-effort, as `pnr-flow` already specifies.
- **Cost**: one or two P&R lane runs (≥ 10 h each on the Azure VM). Each needs the user's go-ahead
  before dispatch. A resumed run that restores the `pre_place` checkpoint and stops after `cts`
  can test the density on a cached netlist in about 6 h.
- **Not changed**: synthesis, the netlist, the floorplan and die size, timing-repair settings,
  routing-layer adjustments, and the `grt` gate.
