# Tasks

Tags:

- **[edit]** plain editing, checked with cheap local validation: `openspec validate`, short OpenROAD calls in the `newt-eda:dev` image.
- **[eda]** loads a full-design checkpoint in the image locally: about 7 min per load under emulation, plus the analysis. Keep the Mac on power with the lid open.
- **[long-run]** a P&R lane dispatch on the VM, 9–13 h. Always ask the user first.

Local inputs: `45035313880`'s `basilisk.cts` checkpoint (from the `pnr-checkpoints` container, as in `stabilize-cts-tree-depth`) and its reports in `target/ihp13/openroad/out/ci-45035313880/`.

## 1. Pin-end strips and the dispatch input (design D1, D2)

- [x] 1.1 **[edit]** In `scripts/pnr/common.tcl`, parse `PNR_GRT_SRAM_END_SIDES` (empty = `both` for now, `both`/`pin`, else an error naming the variable) and add the `pin` branch to `pnr_apply_sram_metal5_adjustment` per D1. That means a strip only on instances wider than tall, at the end nearest `A_DIN[0]`, and an error naming the instance and master when the pin is missing. Extend the log line with the end choice. Verify with a short image call that sources `common.tcl` with `both`, `pin`, `` and `sideways`: the first three parse, and the last errors naming the variable.
- [x] 1.2 **[edit]** Add the `sram_end_sides` input to `.github/workflows/pnr.yml`, wired into `PNR_GRT_SRAM_END_SIDES` on the `run-pnr` line. Document it in `run_pnr.sh`'s header and `docs/pnr-pipeline.md` (input list, now "seventeen"). Verify that `actionlint` passes on `pnr.yml` and that the input count is 17.
- [x] 1.3 **[edit]** Confirm that defaults are unchanged: with every new and existing input empty, the parsed values are `both`, end share 0 and repair 1, and no strip is added (the proc returns before the strip code). Check it with the same image call as 1.1. Run `openspec validate clear-remaining-router-markers --strict`.

## 2. Local checks before VM time (design D3, D4)

- [x] 2.1 **[eda]** IR-drop comparison per D3, on `45035313880`'s `cts` checkpoint: `analyze_power_grid -source_type STRAPS` on VDD and VSS, then `pdn_remove_repair_straps_checked` in the same process, then again. Record the worst drop per net and in the eight gap windows, before and after, plus run time and peak memory. Gate: worst drop per net up by at most max(10 %, 5 mV). Otherwise stop and ask the user.

  **Result (2026-11-23): gate passed.** Setup: `pnr_load basilisk.cts`, `set_wire_rc` Metal3 signal / Metal5 clock, `estimate_parasitics -placement`, `report_wns`/`report_tns`, then `set_power_activity -global -activity 0.1 -duty 0.5`. The timing update is required: without it, `report_power` gave infinite switching power on most instances, and every PSM node voltage came out NaN. STA power 0.92 W (the flow's `cts` report: 1.00 W, different wire RC); PSM's total power 0.599 W. Removal: 10 straps, 1,404 shapes under them, both power-grid checks `ok (0 pre-existing)`.

  | net | worst drop before | after | change |
  | --- | ---: | ---: | ---: |
  | VDD | 0.888 mV | 0.888 mV | 0 |
  | VSS | 1.347 mV | 4.936 mV | +3.59 mV (+266 %; the allowance is 5 mV, so it passes at 72 % of it) |

  Gap windows (x ± 45 µm around each strap, over its y span), worst drop on the analysed net, before → after:

  | strap | VDD | VSS |
  | --- | ---: | ---: |
  | VDD x 6,150, y 536–666 | 0.059 → 0.120 | 0.153 → 0.400 |
  | VDD x 6,150, y 392–523 | 0.027 → 0.062 | 0.038 → 0.065 |
  | VSS x 7,030, y 388–519 | 0.027 → 0.027 | 0.012 → 0.073 |
  | VSS x 7,030, y 540–670 | 0.041 → 0.044 | 0.114 → 0.333 |
  | VSS x 5,298, y 388–519 | 0.139 → 0.139 | 0.093 → 0.588 |
  | VSS x 5,298, y 540–670 | 0.154 → 0.154 | 0.304 → 4.936 |
  | VSS x 2,106, y 388–519 | 0.127 → 0.127 | 0.110 → 1.150 |
  | VSS x 2,106, y 540–670 | 0.120 → 0.120 | 0.280 → 3.905 |

  The worst VSS node moves from Metal1 (4,703, 669) to Metal1 (5,274, 540), inside the x 5,298 window. `STRAPS` sources make the absolute values optimistic; only the change is gated. Run time 1 h 39 min under emulation (load ~7 min; per analysis 853 / 1,241 s before, 274 / 281 s after), peak memory 12.4 GiB (VmHWM 13,023,140 kB).
- [x] 2.2 **[eda]** Global-routing check per D4 on the same checkpoint, with `PNR_GRT_SRAM_END_METAL5_ADJUST=0.5 PNR_GRT_SRAM_END_SIDES=pin`. Verify the strip list: one per horizontal SRAM, the end matching its orientation (east at R180, west at R0), none on the R90 macros. Record `grt` overflow and the Metal5 guide segments in the D and A windows against the run's own `basilisk_route.guide`. Expect fewer in D and no rise in A. If A rises, stop and ask.

  **Result (2026-11-23): as expected.** Same calls as `grt.tcl` (`pnr_load basilisk.cts`, pad dont-touch, dont-use, `pnr_apply_routing_layers`, `global_route -congestion_iterations 14 -allow_congestion`). Strip list: 32 SRAMs, `SRAM-end Metal5 adjustment: 0.5 over 20 strips (40 um, pin end)`. All 13 R180 macros got the east end and all 7 R0 the west end, and none of the 5 R90 and 7 R270 macros got a strip. D-cache bank 0's cut `__1` (R180, x 6,216.50–7,000.98, y 544.56–663.34) has its strip at x 6,960.98–7,000.98, over the D markers. `cut_high` (R90), north of marker A, has none.

  | | `45035313880` | pin-end strips 0.5 |
  | --- | ---: | ---: |
  | `grt` overflow (total) | 6,027 | 6,271 (+244, +4 %) |
  | Metal5 overflow | 3,911 | 3,998 |
  | max H / V | 13 / 13 | 15 / 13 |
  | wirelength | 151,835,569 µm | 151,848,729 µm (+0.01 %) |
  | Metal5 guides, D window (east 40 µm of bank 0 cut `__1`) | 267 segments, 109 nets | 210 (−21 %), 94 nets |
  | Metal5 guides, A window (x 478–508, y 815–845) | 94 segments, 52 nets | 77 (−18 %), 46 nets |

  The reference guides come from the VM (16 vCPU) and these from a local 6-core run of the same image. The difference is attributed to the strips by the flow's determinism, not shown with a local control run. Run time 6 h 27 min under emulation, peak memory 13.5 GiB.

  **Found on the way: Metal5 region adjustments underflow.** `GRT-0114 Underflow in reduce: cap, reducedCap: 0, 65535` appears 64 times in `45035313880` (footprints only), 78 times here and 117 in `43937159728` (both-end strips). An edge with no Metal5 capacity is wrapped to 65,535 instead of staying at 0, so the resource table shows Metal5 with a negative reduction: −28.97 %, −36.26 % and −56.70 % respectively.

  *Cause* (OpenROAD `2c56926971`, `GlobalRouter::computeRegionAdjustments` and `FastRouteCore::addAdjustment`): tiles in a region's first and last row and column get `new_cap = edge_cap − tile_reduce × (1 − r)`, and `std::max(new_cap, 1)` only protects edges with `edge_cap > 0`. On an edge already at 0, the result is negative and is passed as `uint16_t`, so −1 and −4 become 65,535 and 65,532, the two values in the logs. `addAdjustment` then sets the edge's 3D capacity to that value and leaves the 2D graph unreduced (`reduce = 0`).

  *Effect, measured from the guides* (Metal5 nets per vertical tile edge, 6.3 µm tiles, 13 tracks): no edge carries more than 18 nets in either run (the reference: 41 edges at 15–18; this run: 40). That is within ordinary overflow (Metal5 max V overflow 6), so the router never piled onto the inflated edges. This fits the 2D graph limiting demand. The busiest edges sit in the gap east of D-cache bank 0's cut `__1` (x 7,002–7,084, y 617–693, outside every footprint), the crowding behind the D and B markers. Only 3 of them sit on an SRAM's border tile. A geometric replay of the adjustments from the Metal5 supply shapes did not reproduce the logged counts (GRT's obstruction model is not matched), so the exact edges are not located. Recorded as an OpenROAD defect with no measured effect on this change. Not fixed here.
- [x] 2.3 **[edit]** Rebase on `main` and open the PR with groups 1–2 and the change artifacts, recording 2.1 and 2.2 here. After the user merges, run 1 dispatches.

## 3. Measured runs (design D5)

- [ ] 3.1 **[long-run]** *(ask the user first)* Run 1: dispatch on `main` with `pdn_repair_channels=0`, everything else empty, no resume. Save `pnr-reports` under `target/ihp13/openroad/out/ci-<run>/`. Verify:
  - the floorplan logged repair off, 0 short straps and both power-grid checks `ok`;
  - the `cts-kept` line;
  - `drt ok` and `final ok`.

  Compare with `45035313880` per D5, and stop at any row that says ask.
- [ ] 3.2 **[long-run]** *(ask the user first)* Run 2: resume from run 1 with `resume_exclude=grt grt_repaired ant_jumper ant drt final`, `pdn_repair_channels=0 sram_end_metal5_adjust=0.5 sram_end_sides=pin`. Save the reports. Verify:
  - `cts` and earlier were restored;
  - every routing stage logged the pin-end strips with the count from 2.2;
  - `drt ok`, `final ok`.

  Compare with run 1 and `45035313880` per D5, and give the user the outcome row.
- [ ] 3.3 **[edit]** Add a `docs/infra-plan.md` record: the 22 markers by group, D3's IR figures, D4's window counts, both runs' table and the outcome row. Verify that the numbers match the reports.

## 4. Adoption (design D6)

- [ ] 4.1 **[edit]** Only on D5's adopt row: in `common.tcl`, flip the empty defaults to repair 0, end share 0.5 and sides `pin`. Leave `power_grid_stripes.tcl`'s fallback at 1. Update `pnr.yml`'s input descriptions, `run_pnr.sh`'s header and `docs/pnr-pipeline.md`. Name run 2 as the PPA and router reference in `docs/infra-plan.md`. Verify with the image call from 1.1 that empty inputs now parse as 0 / 0.5 / `pin`, and that `chip.tcl`'s path still keeps the straps.
- [ ] 4.2 **[edit]** Not on the adopt row: revert the default clauses of the two MODIFIED requirements in `specs/pnr-flow/spec.md` (and its Default scenarios) to today's defaults, keeping the pin-end mode. Verify with `openspec validate --strict`. On the adopt row, mark this task "not needed".

## Workflow follow-up

- On adoption, re-run the signoff DRC probe on run 2's DEF, so DRC and PPA come from one build. It runs locally for about 7 h; ask first.
- Archive the change after the record (and the adoption PR, if any) is merged.
