# Proposal

## Why

The two Hyperbus delay-line macros (`i_delay_tx_clk_90`, `i_delay_rx_rwds_90`, master `delay_line_D4_O1_6P000`) get no power. `check_power_grid` reports them on every run, with their 12 Metal1 rails per net at x 388.16–428.0 µm, y 4093–4181 µm (`docs/infra-plan.md`, 2026-11-17 record). A chip built from this layout would have an unpowered Hyperbus clock delay, so a fabricated part could not use its HyperRAM. The flow never checks its power grid (`verify 0`), so nothing has caught this.

A read-only look at run `43937159728` (2026-11-17) found the mechanism:

- **The macro can only take power on Metal1.** The LEF abstract (`src/mc_delay/delay_line_D4_O1_6P000.abst.lef`) has six VDD and six VSS pins, all full-width Metal1 rails at the row pitch. Its obstructions cover all of Metal1 and nearly all of Metal2 and Metal3. No via stack from the TopMetal2 straps above can land on its rails. pdngen does not try: `basilisk_pdngen.rpt` lists no failed via at y 4093–4181.
- **The core rails stop 0.44 µm short of it on both sides.** pdngen trims the follow-pin Metal1 rails around the macro. They end at x 387.72 µm and restart at x 428.44 µm, while the macro's rails span 388.16–428.0 µm. The floorplan places the macro on a double-row boundary so that its rails line up with the core rails ("essentially multi-row standard cells", `floorplan_ring_4way.tcl`), so the layout is meant to connect them by abutment. The trim leaves a gap.

## What Changes

- **Bridge the gaps after `pdngen`.** For every delay-line instance, the floorplan adds a short Metal1 supply shape between each same-net core follow-pin rail and the matching macro rail, where the rail stops less than 1 µm short. The floorplan logs how many bridges it added. It fails if a delay line has a supply pin rail that no core rail reaches on either side.
- **Check the power grid on every run.** After the bridges, and after the optional strap removal, the floorplan runs `check_power_grid` on VDD and VSS. It fails the stage before saving its checkpoint if either net reports any unconnected shape or instance. Today's only reports are these 14 per net. With the bridges in place, a clean grid becomes the gate, so a later floorplan or pdngen change cannot quietly leave cells unpowered.
- **Measured run.** One VM dispatch from `floorplan` with the lane's defaults. It confirms that both grid checks are clean, and that the bridges add no router markers at x 387.7–388.2 or 428.0–428.4 µm. It is compared with run `43937159728` for timing and DRC drift. The result goes into `docs/infra-plan.md`.

Stages touched: **backend** only (`power_grid_stripes.tcl` and a new helper script under `target/ihp13/openroad/scripts/`). Not touched: RTL, sim, synth, sw, CI workflow inputs.

Non-goals:

- Changing where the delay lines are placed, or the core TopMetal2 grid.
- The 421 obstructed Metal1→TopMetal2 vias in `basilisk_pdngen.rpt`. These are stacks pdngen could not drop under the straps, and each rail they touch stays connected through other stacks (the grid check proves it).
- Supply integrity beyond connectivity (IR drop, EM). The bridges only make the macros' rails part of the grid.
- The floorplans the lane does not use (`floorplan_ring.tcl`, `floorplan_slabs*.tcl`). The bridge code runs on any floorplan through `power_grid_stripes.tcl`, but only `floorplan_ring_4way.tcl` is measured.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pnr-flow`: two added requirements. The floorplan connects the delay-line macros' supply rails to the core grid. Every floorplan run checks that both supply grids have no unconnected shapes.

## Impact

- `target/ihp13/openroad/scripts/power_grid_stripes.tcl`: calls the bridge step and the grid check after `pdngen`.
- New `target/ihp13/openroad/scripts/pdn_delay_line_rails.tcl` (SHL-0.51): finds and adds the bridges. The grid check reuses `pdn_check_net` from `pdn_repair_straps.tcl`.
- Floorplan stage time: two more `check_power_grid` calls, about 3 minutes under amd64 emulation. They are probably faster on the VM, and the stage is far from its bound.
- Thesis figures: the measured run's WNS, area and power become the new reference only if the measured run shows the bridges are timing- and DRC-neutral (they add about 1 µm² of Metal1 per rail). Otherwise the drift is recorded and the figures are requoted.
- Cost: one VM run of about 12 h (floorplan onward, lane defaults).
