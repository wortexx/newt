# Proposal

## Why

A large part of global routing's overflow comes from a placement mistake set up by the floorplan. The floorplan keeps a margin between the core edge and every macro that sits against it (`floorPaddingX` = 8 µm, `floorPaddingY` = 14 µm, in `floorplan_ring_*way.tcl`). The placement rows in that margin are never cut, so the placer fills it with ordinary logic. Each cell there is walled in by its macro. The SRAMs obstruct Metal1–Metal4, and the macro power grid takes most of TopMetal1 above them, so a net from the margin can cross the macro horizontally on almost nothing. The rest must squeeze through the gaps between macros, or leave the core and run through the band between the core and the pads. The core power ring uses only TopMetal1/TopMetal2, so Metal2–Metal5 are open there.

Measured on the `grt` checkpoint of run `38094932339` (enlarged die, both SHA-3 arms, legal placement; the run's congestion report lists only 10 k gcell edges per direction, so the percentages below come from a sample):

| finding | value |
|---|---|
| standard cells placed in the margins (east / north / south / west) | 6,308 (2,200 / 1,748 / 1,681 / 679), 3,355 of them buffers and tie cells inserted by repair and CTS |
| nets with global-route guides outside the core | 9,313 |
| sampled overflow over macros, or outside the core | 29.5 % + 10.7 % |
| hottest open-area tile | the 530 µm gap between D-cache tag 3 and LLC tag 3, the way out of the east margin |
| original-netlist cells in the east margin, by module | CVA6 258, USB OHCI 225, SPI host 113 (the other 1,597 there are inserted buffers and tie cells) |

Those three modules are also the ones that dominate the congestion report. Detailed routing on this layout ends at about 2.6 M violations, 85 % of them shorts, and does not converge (`docs/infra-plan.md` Phase 11). This is the first lever there that goes after a cause rather than more routing effort. It is also cheap: it moves no macro and costs about 0.15 mm² of a 31 mm² core.

Measured on the lane, blocking the margins alone made things worse: the displaced cells piled into the already dense SPI host corner and global-route overflow tripled (run `38254112819`). Global placement had been allowed to inflate congested cells by at most ×1.2 (upstream's 2024 tuning), too little to move them out. With that raised to 2.5, the combination cut overflow by 62 % against the baseline and improved WNS at `grt` from −13.12 to −8.96 ns (run `38395368038`; tasks 4.1 and 5.3).

## What Changes

- **No standard cells in the macro-to-core margins.** The floorplan stage blocks placement in every gap between a macro and the core edge no wider than a configured margin width. The default, 20 µm, covers the measured margins of 8.0 µm (east and west) and 14.0 µm (south and north). The blocking covers the length of the macro's side, and a width of 0 turns it off. Neither global placement nor legalization can then put a cell there.
- **Global placement may inflate congested cells harder.** Both `gpl` passes raise `-routability_inflation_ratio_coef` and `-routability_max_inflation_ratio` from 1.2 to 2.5, so routability mode moves cells out of congested regions instead of giving up after about +1 % area per iteration. Without it, the margin blocking triples overflow.
- **The run reports what is left in tight spots.**
  - After detailed placement, a count of cells in the macro margins (expected 0) and a count of cells in narrow channels between two macros. The run's channel figure was 5,976, mostly between the stacked cache-data SRAMs, where the lower macro's pins face the channel.
  - After global routing, the number of nets with route guides outside the core.

  Report only, never a stage failure. A non-zero margin count is a named warning.
- **BREAKING for comparisons.** P&R figures before and after this change come from different placements. The thesis reference and both-arms figures may only be compared when both were placed with it.
- **Docs.**
  - `docs/infra-plan.md` Phase 11 records the diagnosis and the validation outcome.
  - `docs/pnr-pipeline.md` describes the `floorplan` stage's blocking and the new report lines.

Flow stages touched: **backend** (floorplan scripts, OpenROAD stage scripts including global placement, `run_pnr.sh`) and **docs**. No RTL, synthesis, simulation, software or CI-workflow change.

## Non-goals

- **Blocking the channels between macros.** Those cells are reported, not moved. Whether to block them is decided from the validation run's numbers, in a separate change, so that one run measures one cause.
- **Fixing `addHaloToBlock`.** The helper in `floorplan_util.tcl` computes a halo box and discards it, so the macro "halos" in the floorplan have never existed. Making it work would change placement around every macro. It is recorded as a finding, not fixed here.
- **Moving macros or changing the die.** These remain Phase 11's last resort.
- **Requoting the thesis P&R figures.** That stays the open Phase 11 decision. It needs both sides re-run with this change.
- **Detailed-routing convergence as an acceptance criterion.** Success is measured at global routing, which the thesis quotes.
- **Legacy `chip.tcl`.**

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pnr-flow`: two changes.
  - New requirement: standard cells are kept out of the margins between macros and the core edge, with the margin and channel counts reported after placement.
  - The run reports, after global routing, how many nets are routed outside the core.

## Impact

- **Code:**
  - `target/ihp13/openroad/scripts/floorplan_util.tcl` (new blocking helper)
  - `target/ihp13/openroad/scripts/floorplan_ring_4way.tcl` and `floorplan_ring_2way.tcl` (call it)
  - `target/ihp13/openroad/scripts/pnr/{common,dpl,grt}.tcl` (reports)
  - `target/ihp13/openroad/scripts/pnr/gpl.tcl` (routability inflation)
  - `target/ihp13/openroad/run_pnr.sh` (surface the report lines)
- **Checkpoints:** every checkpoint from `floorplan` on is invalidated. A run with this change cannot resume from an older run.
- **Runtime:** about unchanged (probe B: `gpl` +12 min, `grt` −11 min against the baseline). The blocked area is about 0.5 % of the core.
- **Risk:**
  - The margin cells move into the open area next to the macros. If the right column's gaps were also carrying through-traffic, the hotspot may only shift. The validation run's overflow figures will show that.
