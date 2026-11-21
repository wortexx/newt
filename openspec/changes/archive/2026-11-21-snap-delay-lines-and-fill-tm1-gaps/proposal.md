# Proposal

## Why

The first signoff DRC of the routed chip was run on 2026-11-20. It used IHP's KLayout deck (`sg13g2.lydrc`, the PDK's minimum rule set) on run `44382400639`'s final DEF, streamed to GDS in a scratch container. The whole die was covered in 56 tiles of 1 mm. Standard-cell logic and routing are clean. Apart from density and the IO ring (no fill, no IO GDS), every remaining item is inside IP as shipped (the SRAMs' bar contacts, the delay line's own layers) except 696. Those are layout this flow creates, and they make it fail signoff even if all IP were waived:

- **332 `Cnt.a`, 332 `Cnt.b` and 20 `Act.b` at the delay lines.** The floorplan places both `delay_line_D4_O1_6P000` instances at x 388.16 µm. The rows start at x 380.16 µm with a 0.48 µm site, so that is 16.67 sites in, 0.16 µm off the grid. (Their y is snapped to double rows.) The macro has the same edge profile as a standard cell: Activ to the edge, and tie contacts 0.16 µm inside it on a 0.48 µm pitch. So off the grid, its rail contacts overlap the contacts of the cells above and below at a 0.16 µm offset. That produces merged 0.32 µm contacts (`Cnt.a`) and 0.16 µm spaces (`Cnt.b`) along all four horizontal edges. On the east side, its Activ ends 0.16 µm from the first cell's (`Act.b`). On the 2026-11-20 summary these `Cnt.a` were counted as delay-line IP. They are not: the macro alone has none.
- **12 `TM1.b` over the stacked SRAM columns.** On each R90/R270 column (x 404–478 µm and 7107–7181 µm), the two TopMetal2 macro straps carry two kinds of via stack. One goes down to the SRAM's Metal3/Metal4 ring. The other goes down to the Metal1 rail in the channel between two stacked SRAMs. Each stack leaves a 1.9 µm TopMetal1 pad. At three channels per column, the two pads end 0.26, 0.78 or 1.14 µm apart on the same net. The rule is 1.64 µm. pdngen's own notch fill (`DRCFILL`) does not close the gap, because the two stacks come from different grids (the core grid and the SRAM's macro grid).

A probe moved both delay lines +0.16 µm onto the grid in the scratch GDS and re-ran the deck on a window around them. All 684 delay-line items disappeared. The only new items were 20 `M1.b` where the old rail bridges no longer reached the moved pins, and the flow recomputes those bridges from the macro's position.

Neither problem showed up before. The router's DRC does not check base layers, and it does not check spacing between same-net special-net pads. This is the first time the flow has been checked against the foundry deck.

## What Changes

- **Place the delay lines on the site grid.** Both lane floorplans round each delay line's x up to the next site of the rows it covers, so it abuts the neighbouring cells as the floorplan's own comment intends ("essentially multi-row standard cells"). Its y stays on the double-row grid. After placing, the floorplan checks that every delay-line instance's origin is on the row's site grid and row grid, and fails the stage if not. The existing rail bridges are recomputed from the new position, as before.
- **Close same-net TopMetal1 gaps in the power grid.** After pdngen, the delay-line bridges and the optional strap removal, the floorplan finds every pair of VDD or VSS TopMetal1 shapes on the same net whose facing edges overlap and are less than the layer's minimum spacing apart. It fills each gap with a TopMetal1 shape of that net. It logs the number of fills. It fails the stage if a fill would touch a shape of another net. The supply-grid check that already runs on every floorplan follows, unchanged.
- **Measured run.** One VM dispatch from `floorplan` with the lane's defaults. Then the same scratch DRC probe is re-run on the final DEF, over the delay-line window and both SRAM columns (or the full die). The pass condition is 0 `Cnt.a`/`Cnt.b`/`Act.b`/`M1.b` at the delay lines' edges and 0 `TM1.b`. The run is also compared with `44382400639` for timing, router markers and antenna counts. The result goes into `docs/infra-plan.md`, together with the full-die DRC baseline from 2026-11-20.

Stages touched: **backend** only (`floorplan_ring_2way.tcl`, `floorplan_ring_4way.tcl`, `floorplan_util.tcl`, `power_grid_stripes.tcl` and a new helper script under `target/ihp13/openroad/scripts/`). Not touched: RTL, sim, synth, sw, CI workflow inputs.

Non-goals:

- Violations inside IP as shipped: the SRAMs' bar-contact `Cnt.a` and their empty bit-cell arrays, and the delay line's own Passiv, PEmWind and `M2.a` shapes. These are for a waiver list, or for a later PDK or IP pin.
- Metal fill and the density rules. The IO ring, whose cells have no GDS in the pinned PDK. A KLayout or GDS step inside the flow. These are separate changes, and this change's DRC check stays a scratch probe.
- A placement halo around the delay lines. On the grid, the macro abuts standard cells cleanly, as the probe shows, so a halo would only cost sites.
- The SRAMs' x positions, which share `floor_leftX` with the delay lines and are equally off the grid. Their rows are cut around them (`cut_rows`), so no cell abuts them, and the DRC found nothing there.
- The floorplans the lane does not use (`floorplan_ring.tcl`, `floorplan_slabs*.tcl`).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pnr-flow`: two added requirements. The floorplan places the delay-line macros on the standard-cell site grid. The floorplan closes same-net TopMetal1 gaps in the supply grid.

## Impact

- `floorplan_ring_2way.tcl` and `floorplan_ring_4way.tcl`: delay-line x rounded up to the site grid.
- `floorplan_util.tcl`: a small proc that does the rounding and the on-grid check, shared by both floorplans.
- New `target/ihp13/openroad/scripts/pdn_fill_gaps.tcl` (SHL-0.51), called from `power_grid_stripes.tcl` before `pdn_check_grid`.
- Placement: the delay lines move 0.16 µm east. The rail bridges change length by the same amount (still under the 1 µm reach), and the west margin blockage grows from 8.00 to 8.16 µm.
- Thesis figures: about 12 small TopMetal1 shapes and a 0.16 µm shift. The measured run's WNS, area and power become the new reference if they stay within run-to-run drift. Otherwise the drift is recorded and the figures are requoted.
- Cost: one VM run of about 12 h (floorplan onward, lane defaults), plus a local DRC probe of 1–5 h.
