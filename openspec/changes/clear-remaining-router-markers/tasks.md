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

- [x] 3.1 **[long-run]** *(ask the user first)* Run 1: dispatch on `main` with `pdn_repair_channels=0`, everything else empty, no resume. Save `pnr-reports` under `target/ihp13/openroad/out/ci-<run>/`. Verify:
  - the floorplan logged repair off, 0 short straps and both power-grid checks `ok`;
  - the `cts-kept` line;
  - `drt ok` and `final ok`.

  Compare with `45035313880` per D5, and stop at any row that says ask.

  **Result (2026-11-24): run `45262070315`, 11 h 0 min, all stages ok.**
  - Floorplan: `PDN channel repair: off`, `channel-repair straps removed: 10 (1404 shapes under them)`, both checks `ok (0 pre-existing)`, 0 short straps.
  - CTS: build 1 deep (14 levels, 32,143 buffers), `cts-kept build=2` (11 levels, 14,383 buffers, as in the reference).
  - `drt ok droute_end_iter=28`, `final ok`.

  | | `45035313880` | run 1 |
  | --- | ---: | ---: |
  | WNS / TNS at `grt` | −12.89 / −98,517.91 ns | −8.75 / −73,790.32 ns |
  | `grt` overflow (max H / V / total) | 13 / 13 / 6,027 | 12 / 12 / 6,025 |
  | markers, total | 22 | 10 |
  | group B (repair-strap pads) | 7 | 0 |
  | group D (bank 0 cut `__1` east end) | 14 | 1, Metal5 at (6,997.4, 674.1), 11 µm north of the macro's top edge |
  | group A (south of `cut_high`) | 1 | 1, Metal2 at (487.7, 827.8) |
  | new: `slink_rcv_clk_i_0_` vs VDD, Metal3 | 0 | 8, x 6,228–6,232, y 1,255–1,331 |
  | antenna nets / pins after `drt` | 8,449 / 11,159 | 8,319 / 10,908 |
  | clock / total power at `grt` | 0.372 / 1.04 W | 0.376 / 1.04 W |
  | design area after CTS | 18,323,579 µm² | 18,293,746 µm² |
  | `drt` time | 7 h 39 min | 5 h 40 min |

  The macros are placed identically. The new cluster is one clock net, the serial-link receive clock, shorting VDD on Metal3. It is present in every intermediate report from iteration 5 (251 markers in the window) to the end, and absent from all of the reference's. Its clock tree went from a 65 µm span in the reference to 2,517 µm here (depth 3, 44 → 48 buffers), so the strap removal moved its registers apart in placement. D5: "B clear, WNS more than 0.5 ns worse" does not apply (WNS is 4.14 ns better).

  *The new cluster, probed on run 1's `drt` checkpoint.* The shorting net is the pad net `slink_rcv_clk_i_0_`, routed with `CTS_NDR_0`, which CTS gives to root-level clock nets.
  - In the reference, the pad (`pad_slink_clk_i`, east edge, at (7,288, 1,020)) drives the tree's root buffer directly, at (7,073, 3,145).
  - In run 1, the serial-link registers spread out and the root buffer sits at (5,243, 2,601). The pad net is now longer than the 3,162 µm maximum wire length, so `repair_clock_nets` inserted `wire504239` (`sg13g2_buf_16`) at (6,215, 1,852).
  - The pad-to-`wire504239` route runs a vertical Metal3 trunk from y 1,203 to y 1,377 at x 6,225–6,234. That is inside the via column of the VDD TopMetal2 strap at x 6,230.16, which drops a 6 µm-wide via stack to every Metal1 rail, one every 7.56 µm. The 8 shorts sit on those rails.

  The power grid there is identical in both runs; only the clock route moved onto it. The serial-link cluster comes from the placement shift that the strap removal caused, not from the grid change. Run 2 resumes from run 1's `cts` and keeps `wire504239` where it is, so the cluster can stay. Its routing could still change, because `grt` reruns.
- [x] 3.2 **[long-run]** *(ask the user first)* Run 2: resume from run 1 with `resume_exclude=grt grt_repaired ant_jumper ant drt final`, `pdn_repair_channels=0 sram_end_metal5_adjust=0.5 sram_end_sides=pin`. Save the reports. Verify:
  - `cts` and earlier were restored;
  - every routing stage logged the pin-end strips with the count from 2.2;
  - `drt ok`, `final ok`.

  Compare with run 1 and `45035313880` per D5, and give the user the outcome row.

  **Result (2026-11-24): run `45365266924`, 7 h 36 min, 0 markers.**
  - `floorplan` through `cts` were logged `skipped resume`.
  - `SRAM-end Metal5 adjustment: 0.5 over 20 strips (40 um, pin end)` appears once each in `grt`, `grt_repair`, `ant` and `drt`, the count from 2.2.
  - `drt ok droute_end_iter=28`, `drt-violations final=0`, `final ok`.

  | | `45035313880` | run 1 `45262070315` | run 2 `45365266924` |
  | --- | ---: | ---: | ---: |
  | repair straps / power-grid checks | 10 / clean | 0 / ok | 0 / ok (restored) |
  | WNS at `grt` | −12.89 ns | −8.75 ns | −7.63 ns |
  | TNS at `grt` | −98,517.91 ns | −73,790.32 ns | −70,143.86 ns |
  | `grt` overflow (max H / V / total) | 13 / 13 / 6,027 | 12 / 12 / 6,025 | 13 / 12 / 6,795 |
  | markers: B / D / A / other | 7 / 14 / 1 / 0 | 0 / 1 / 1 / 8 | 0 / 0 / 0 / 0 |
  | antenna nets / pins after `drt` | 8,449 / 11,159 | 8,319 / 10,908 | 8,317 / 10,848 |
  | clock / total power at `grt` | 0.372 / 1.04 W | 0.376 / 1.04 W | 0.378 / 1.05 W |
  | design area | 18,323,579 µm² | 18,293,746 µm² | 18,293,746 µm² |
  | `drt` time | 7 h 39 min | 5 h 40 min | 5 h 47 min |

  The serial-link clock shorts were still in run 2's iteration-20 report (33 of its 44 markers), and gone by iteration 25. Its pad net still has `wire504239` at the same place, so the router cleared it late rather than avoiding it. This deserves a look if a later run brings it back.

  **Outcome row: adopt.** B and D have no markers, there are 0 in total, and WNS is 5.26 ns better than `45035313880` (within 0.5 ns is required, worse would fail).
- [x] 3.3 **[edit]** Add a `docs/infra-plan.md` record: the 22 markers by group, D3's IR figures, D4's window counts, both runs' table and the outcome row. Verify that the numbers match the reports.

## 4. Adoption (design D6)

- [x] 4.1 **[edit]** Only on D5's adopt row: in `common.tcl`, flip the empty defaults to repair 0, end share 0.5 and sides `pin`. Leave `power_grid_stripes.tcl`'s fallback at 1. Update `pnr.yml`'s input descriptions, `run_pnr.sh`'s header and `docs/pnr-pipeline.md`. Name run 2 as the PPA and router reference in `docs/infra-plan.md`. Verify with the image call from 1.1 that empty inputs now parse as 0 / 0.5 / `pin`, and that `chip.tcl`'s path still keeps the straps.
- [x] 4.2 **[edit]** Not on the adopt row: revert the default clauses of the two MODIFIED requirements in `specs/pnr-flow/spec.md` (and its Default scenarios) to today's defaults, keeping the pin-end mode. Verify with `openspec validate --strict`. On the adopt row, mark this task "not needed". **Not needed:** run 2 met the adopt row, and the spec deltas already state the adopted defaults.

## Workflow follow-up

- On adoption, re-run the signoff DRC probe on run 2's DEF, so DRC and PPA come from one build. It runs locally for about 7 h; ask first.
- Archive the change after the record (and the adoption PR, if any) is merged.
