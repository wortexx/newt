# Design

## Context

See proposal.md - Why for the DRC results. Everything below comes from run `44382400639`'s final DEF and the scratch DRC probe of 2026-11-20. The probe used KLayout 0.28 in `ubuntu:24.04`, the pinned PDK's `sg13g2.lydrc` run in batch mode, and the scripts in the session scratchpad. Task 4 records them in `docs/infra-plan.md`.

**Delay line.** `delay_line_D4_O1_6P000` (LEF 39.84 × 41.58 µm, CLASS BLOCK) is 83 sites wide and 11 rows tall. Its GDS edge profile matches the standard cells. For both the macro and `sg13g2_fill_1`/`sg13g2_buf_16`:

- Activ and Metal1 reach x = 0 and the cell's width;
- tie contacts sit at 0.16 µm + k·0.48 µm;
- pSD overhangs by 0.07 µm and NWell by 0.24 µm.

The rows are `ROW_n CoreSite 380160 … STEP 480`, with orientations alternating N/FS. `floorplan_ring_{2,4}way.tcl` place both instances R0 at x = `floor_leftX` = core left + `floorPaddingX` (8.0) = 388.16 µm. They round y to a double row (`doubleSite`), but not x. 8.0 / 0.48 = 16.67, so the macro's contacts sit 0.16 µm off the cells'. The y rounding already keeps the rail parity right (N row at the bottom), which the rail bridges rely on.

**Snap probe.** Shifting both instances +0.16 µm in the scratch GDS and re-running the deck on a 75 × 125 µm window removed all 332 `Cnt.a`, 332 `Cnt.b` and 20 `Act.b`. It added 20 `M1.b` where the DEF's rail bridges (built for 388.16) stop 0.16 µm short of the moved pins. Everything else in the window was unchanged: IP layers and clip-edge artifacts.

**Strap gaps.** `sram_power_rotated` adds a pair of 8 µm TopMetal2 straps to `core_grid` over each R90/R270 SRAM column. Two kinds of via stack drop from them:

- `core_grid`'s `TopMetal2 → Metal1` connect drops a stack onto each follow-pin rail in the 14 µm channels between stacked SRAMs;
- the rotated macro grid's `TopMetal2 → Metal3/Metal4` connect drops a stack onto the SRAM ring.

Each stack leaves an 8 × 1.9 µm TopMetal1 pad, written as a `DRCFILL` path of width 1900 plus the via. At y 1630.8/1632.96, 2242.28/2245.32 and 2857.68/2860.36 (west column), and at the matching y on the east column, the two pads end 0.26, 1.14 and 0.78 µm apart. Both pads are on the same net and the same strap. pdngen merges notches only within one grid's shapes, so it leaves them. drt does not flag them either. The tech LEF gives TopMetal1 `SPACING 1.64`, the same value as the deck's `TM1.b`.

## Goals / Non-Goals

**Goals:**

- Zero flow-created items under the minimum deck at the delay lines and the SRAM columns, with no change to the IP.
- Both fixes are generic: the snap reads the site and row origin from the database, and the fill reads the spacing from the tech layer. No coordinates are hardcoded.

**Non-Goals:**

- Moving the SRAMs onto the site grid. Their rows are cut, and the DRC found nothing at their edges.
- Changing pdngen's stack placement or the SRAM column spacing to avoid the gaps.
- Checking DRC inside the flow (proposal.md, Non-goals).

## Decisions

### D1. Round the delay lines' x up to the site grid, and check it

A proc in `floorplan_util.tcl` takes the intended x in microns and returns it rounded up to the row grid: row origin + ⌈(x − origin) / site width⌉ · site width. It reads the origin and site width from the row under the delay line (`dbRow` origin and `dbSite` width, via `dpl::get_row_site`, which the floorplans already use for `siteHeight`). Rounding up keeps the gap to the core edge at or above `floorPaddingX`. The macro moves from 388.16 to 388.32 µm. Both lane floorplans use it for `X` in their delay-line block. y is already rounded and stays as it is.

After `placeInstance`, the same file's check proc confirms that every instance of the delay-line master has `(x − row origin) mod site width = 0` and that y is on a row boundary. It errors with the instance name and position otherwise, and logs both positions. The check catches a later edit to `floorPaddingX` or the die scale (`pnr_die_scale` moves the core edge) that silently breaks the grid again.

Alternatives considered:

- *A placement halo east of the macro (the change's first scope).* It removes only the 20 `Act.b`. The 664 contact items are on the top and bottom edges, against rows a side halo does not touch.
- *Cutting the rows above and below the macro.* That would cut the follow-pin rails the bridges connect to, and give up the abutment the floorplan intends.
- *Changing `floorPaddingX` to a site multiple (8.16).* It also moves every SRAM and changes the margin geometry everywhere, for the same effect on the delay lines.

### D2. Same-net TopMetal1 gap fill after pdngen

A new `pdn_fill_gaps.tcl` provides `pdn_fill_same_net_gaps {layer}`. `power_grid_stripes.tcl` calls it for `TopMetal1` after `pdn_bridge_delay_line_rails` and the optional strap removal, and before `pdn_check_grid`. For each of VDD and VSS:

1. Collect the net's TopMetal1 rectangles: the non-via wires of its special wires (the `DRCFILL` and `STRIPE` boxes), plus the TopMetal1 box of every via. The via boxes come from the via's block-via or tech-via layer boxes, offset by the via's position.
2. Bucket them by x-interval. Sort each bucket by y and check neighbours, then do the same with x and y swapped. Two shapes form a gap when their projections overlap by at least the layer's minimum width and the space between them is greater than 0 and less than the layer's `SPACING` from the tech LEF. The overlap threshold keeps out corner-to-corner pairs.
3. The fill is the overlap × the gap. Before adding it, check every TopMetal1 shape of the other supply net. The floorplan runs before routing, so no signal shapes exist yet. Error if any touches the fill.
4. Add the fill as a `DRCFILL` box on the swire of one of the two shapes, and log `Same-net TopMetal1 gaps filled: N`.

Expected N is 12, six per column.

The fill shape is a plain wire, so `pdn_check_grid` keeps working. It only adds same-net metal. The proc takes the layer as an argument, but only TopMetal1 is called. No other layer showed same-net gaps in the DRC.

Alternatives considered:

- *Dropping the channel's TopMetal2 → Metal1 stack.* That needs pdngen options it does not have, or editing the stack after the fact. It also weakens the channel rail's supply, and `check_power_grid` would have to prove the rail still connects through the ring.
- *Moving the stacked SRAMs further apart.* That changes the floorplan and timing for 12 small shapes, and the right distance depends on rail parity.
- *A waiver.* These are our own shapes, and the rule is a real foundry rule.

### D3. Order in the floorplan

The snap happens where the delay lines are placed today, before `block_macro_core_margins` (which then blocks the 8.16 µm west gap) and before the power grid. So `pdn_bridge_delay_line_rails` builds its bridges against the new pin edges, and `pdn_fill_same_net_gaps` sees the final grid. No other stage changes.

## Risks / Trade-offs

- [The move changes the bridges' lengths: the west bridge grows by 0.16 µm, the east one shrinks by 0.16 µm.] → Both stay within the 1 µm reach that `pdn_bridge_delay_line_rails` enforces. `pdn_check_grid` fails the stage if a rail ends up unconnected.
- [pdngen trims the core rails differently around the moved macro.] → Same guards as above. The floorplan log's bridge count is compared with `44382400639`'s.
- [The fill code mistakes a gap to a different-potential shape for a same-net one.] → It only pairs shapes of one net. It checks every TopMetal1 shape of the other supply net against each fill, errors instead of creating a short, and `check_power_grid` still runs afterwards.
- [Another off-grid abutment exists that the probe windows missed.] → The full-die sweep found flow-created items only at the delay lines and the SRAM columns. The measured run re-runs at least those windows.
- [The DRC probe is a scratch setup and not part of the flow.] → Its scripts and the deck generator are described in `docs/infra-plan.md` with the results, so the check can be repeated. Moving it into the flow is a separate change.

## Migration Plan

Reverting either floorplan or `power_grid_stripes.tcl` edit restores the old behaviour. Neither change touches checkpoints from before this change. A resumed run picks the changes up only from `floorplan` onward.
