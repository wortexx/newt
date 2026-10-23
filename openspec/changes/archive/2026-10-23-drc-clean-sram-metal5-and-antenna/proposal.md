# Proposal

## Why

The first near-clean routed DEF (run `39244019401`) leaves 121 detailed-routing violations, and a read-only check of its checkpoints (docs/infra-plan.md, "What is left of DRC, 2026-10-21") found the causes of both remaining routing problems:

- **The 121 are Metal5 jogs over three SRAMs.** The SRAMs block Metal1–Metal4, and the macro power grid's via stacks leave 8 rows of Metal5 pads over each one. Only 43 % of Metal5 tracks clear every row. Global routing still plans up to 22–32 Metal5 nets in a 6.3 µm gcell column that holds about 5 such tracks. Detailed routing makes up the difference with wrong-way jogs between pad rows, and those jogs are the shorts.
- **Antenna is the larger part of "DRC-clean".** 11,732 nets violate the cumulative-area rule. Antenna repair has been off since it hung on a 101 %-demand layout, and the flow never checks antennas, so no run reports this number today.

## What Changes

- **SRAM Metal5 hold-back for global routing.** A new setting holds back a share of Metal5's capacity inside every SRAM's footprint, applied wherever the existing per-layer adjustments are applied. Empty by default (no hold-back). The P&R lane gains a matching dispatch input.
- **A choice of antenna repair mode.** The `antenna_repair` dispatch input also accepts a jumper-only mode, alongside today's full repair. A fallback run then needs no code edit if diode insertion stalls again. The default stays: no repair.
- **Antenna count on every routed run.** After detailed routing, the flow runs the antenna checker. The run reports the violating nets and pins, from the checker's own output, on a status row and in the run summary. This is reporting only and does not change the run's exit status.
- **One measured run.** Resume run `39244019401` from its `cts` checkpoint with the SRAM Metal5 hold-back and antenna repair, within the 24 h `drt` timeout. Compare it with 121 router violations, 11,732 antenna nets, and WNS −11.02 ns at `grt`. Record the result in docs/infra-plan.md, and whether these settings should become the lane's defaults.

Stages touched: **backend** (OpenROAD stage scripts: `common.tcl`, `drt.tcl`, `run_pnr.sh`) and **CI** (`pnr.yml` dispatch inputs and run summary). Not touched: RTL, sim, synth, sw.

Non-goals:

- Sign-off DRC (KLayout, IHP deck) and metal fill.
- Changing the SRAM power grid, for example fewer or x-aligned via stacks. That is the second-ranked lever, kept for a follow-up if the hold-back is not enough.
- Floorplan changes.
- Making the new settings default. That decision follows the measured run.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pnr-flow`: the detailed-route stage also reports the antenna checker's own counts. Global routing can hold back Metal5 over the SRAMs.
- `ci-pipeline`: the P&R lane's manual dispatch gains an SRAM Metal5 hold-back input, and its antenna-repair input gains a jumper-only mode. The run summary also shows the antenna counts, but that is presentation only and needs no requirement.

## Impact

- `target/ihp13/openroad/scripts/pnr/common.tcl`: a new parsed setting, plus a region adjustment in `pnr_apply_routing_layers` over every SRAM instance.
- `target/ihp13/openroad/scripts/pnr/drt.tcl`: the repair mode, and `check_antennas` after `detailed_route`.
- `target/ihp13/openroad/run_pnr.sh`: a new pass-through variable, and an antenna outcome row next to `drt-violations`.
- `.github/workflows/pnr.yml`: the new input, the extended `antenna_repair` values, and the antenna section in the summary.
- Scheduled runs keep the same layout. They gain one antenna report and one status row, and `drt` takes a few minutes longer for the check.
- Cost: one VM run of about 20–24 h (`grt` onward). Thesis figures are not affected until a later change adopts the settings.
