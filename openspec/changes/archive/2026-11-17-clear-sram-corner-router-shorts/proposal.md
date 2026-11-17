# Proposal

## Why

On the lane's defaults the router stops at 8 shorts, and three runs reproduce them byte for byte (`39906592139`, `40081935481`, scheduled `41133143603`). Iterations 22–28 only move them around, so more iterations will not help. A read-only probe of `41133143603`'s routed DEF (2026-11-16) found two causes, and both are in the flow's own setup, not in the design:

- **3 shorts (A, B) are signal wires crossing a power via stack.** In the channels, every TopMetal2 core stripe drops a stack to each Metal1 rail, with an 8 µm pad on Metal2–Metal5. Two of the three shorts sit under a TopMetal2 **stub** that pdngen's channel repair (`RepairChannelStraps`) added at x 7030. That stub is the one PDN wall in the 90 µm channel east of the D-cache SRAM. pdngen adds 10 such stubs in all (8 in the gaps: VSS at x 2106, 5298 and 7030, VDD at 6150, each over the bottom and middle macro rows; plus a VDD/VSS pair next to an LLC macro at the top right): the core stripe pair (VSS and VDD 54 µm apart, 138 µm pitch) does not put both nets into every 90 µm gap between macros. The flow never asked for these stubs, and it never checks the power grid (`verify 0`).
- **5 shorts (C, D) are Metal5 crossings over a middle-row SRAM, at its east end.** Every R180 SRAM has its pins on its top edge. So the 30 µm gap between the bottom and middle rows is the bottom row's only pin side, and it holds 4,573 cells. Drivers there that feed a *middle*-row pin (`bank_wdata_64_` → `A_DIN[0]`; `net140706` → `A_DIN[1]` of both I-cache `cut_low` macros) must cross the 119 µm macro on Metal5. Metal5 is the only vertical layer there, and they cross where the gap meets the next channel. Unrelated nets take the same Metal5 tracks between the macro's power-pad rows. The full-diode run's single violation (`40907413844`) is at this D-cache corner too.

## What Changes

- **A switch that removes pdngen's channel-repair straps, with a power-grid check.** pdngen always runs channel repair; the pinned OpenROAD has no way to turn it off. A new floorplan setting removes the repair straps after `pdngen`: every TopMetal2 strap shorter than the core, with the via stacks under it. Default: keep them, as today. Without them the gap rails rely on the macro rings' Metal3→Metal1 connections, so the floorplan checks VDD and VSS before and after the removal and fails if the removal leaves any shape unconnected that was connected before. Today's grid already has unconnected shapes (12 Metal1 rails per net at the west edge, around two Hyperbus delay lines), so the check compares, rather than demanding zero. The floorplan logs whether the straps were removed and how many TopMetal2 shapes shorter than the core are left.
- **Extra Metal5 hold-back at the SRAM ends.** A new global-routing setting holds back a further share of Metal5 in a fixed-width strip at both short ends of every SRAM, on top of the existing whole-footprint hold-back. Default 0 (no change). Global routing then plans fewer crossings where they bunch up, and more nets go around the corner.
- **Two dispatch inputs** on the P&R lane, one for each setting. Empty keeps the default.
- **Measured run.** One VM dispatch from `floorplan`, with channel repair off and the end hold-back on, compared against run `40081935481` (run A). If the result is good, an optional resume from its `cts` with the end hold-back off measures the PDN switch alone. The probe findings and the result go into `docs/infra-plan.md`.

Stages touched: **backend** (`power_grid_stripes.tcl`, `scripts/pnr/common.tcl`, `run_pnr.sh`) and **CI** (`pnr.yml` dispatch inputs). Not touched: RTL, sim, synth, sw.

Non-goals:

- **Blocking placement in the gap between macro rows.** It would strand the bottom row's pins, which face only that gap, and push every bottom-row net over the middle row on Metal5. The probe showed it would multiply the C/D mechanism.
- Redesigning the core TopMetal2 grid (pitch, pairing, offsets), or the SRAM macro grid's via pads.
- Short A, under the core stripe pair over the left R90 column. Neither lever targets it.
- Making the settings default and requoting the thesis figures. That is a follow-up, if the measured run supports it.
- Antenna repair and signoff DRC.
- The pre-existing west-edge PDN hole (Metal1 rails at x 388–428 µm, y 4093–4181 µm, and the two Hyperbus delay lines on them, unconnected on both nets). It is recorded in `docs/infra-plan.md` for its own change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pnr-flow`: two added requirements. The floorplan can remove pdngen's channel-repair straps, and then must prove that the removal disconnected nothing. Global routing can hold back extra Metal5 at the SRAMs' ends.
- `ci-pipeline`: the P&R lane's manual dispatch gains two inputs, one for the channel-repair switch and one for the SRAM-end Metal5 hold-back.

## Impact

- `target/ihp13/openroad/scripts/power_grid_stripes.tcl`: the strap removal after `pdngen`, the stub count, and a before/after `check_power_grid` gate when the straps are removed.
- `target/ihp13/openroad/scripts/pnr/common.tcl`: two parsed settings, and end-strip regions added in `pnr_apply_sram_metal5_adjustment`.
- `target/ihp13/openroad/run_pnr.sh`, `.github/workflows/pnr.yml`, `docs/pnr-pipeline.md`: pass-through, inputs, documentation.
- Scheduled runs (paused on branch `pause-scheduled-lanes`) and every quoted thesis figure are unchanged, because both defaults keep today's behaviour.
- Cost: one VM run of about 12 h (floorplan onward, jumper-only antennas), plus an optional run of about 9 h from `cts`.
