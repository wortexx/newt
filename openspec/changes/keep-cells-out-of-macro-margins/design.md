# Design

## Context

See proposal.md for the diagnosis. The facts that shape the approach:

- **Where macros go.** `floorplan.tcl` sources `floorplan_ring_4way.tcl` (the lane's `L1CACHE_WAYS` is 4) or `floorplan_ring_2way.tcl`. Both place every SRAM by hand, relative to `floor_*X/Y`: the core edge moved inwards by `floorPaddingX` (8 µm) or `floorPaddingY` (14 µm). Both end with `cut_rows`, which removes rows under the macros plus a small halo (`-halo_width_x 2`/`7.5`, `-halo_width_y 1`). Nothing removes the rows in the padding.
- **Measured gaps** between macro and core edge on run `38094932339`'s floorplan (die scale 1.10): 8.00 µm east and west, 14.00 µm south and north, i.e. exactly `floorPaddingX/Y` from the site-snapped core edge (380.16, 381.78, 6396.96, 5567.94 µm). (The exploration first quoted 8.04–16.06 µm, measured from the unsnapped 380/5570 µm.)
- **Macro halos do not exist.** `addHaloToBlock` (`floorplan_util.tcl`) computes a box and discards it, so its blockage is never created. Only `cut_rows` keeps cells off the macros' edges.
- **Existing helpers.** `floorplan_util.tcl` already has `add_macro_blockage`, which creates a hard placement blockage over the box spanning two macros via `odb::dbBlockage_create`. The new helper follows that pattern.
- **Settings pattern.** A Tcl default in `scripts/pnr/common.tcl` with a `PNR_*` override, documented in `run_pnr.sh`'s header. `floorplan.tcl` sources `common.tcl` before it sources the floorplan script, so the floorplan can read the setting.
- **Dispatch inputs.** `pnr.yml` already has 9 of GitHub's 10. This change adds none (D5).
- **Reports.** `run_pnr.sh`'s `report_placement_state` already turns `dpl`'s log into the one-line placement report and raises `::warning::` lines. `grt.tcl` writes `basilisk_route.guide` (about 500 MB, about 1 M nets). Both are the natural hooks.

## Goals / Non-Goals

**Goals:**
- Margins empty by construction: no stage can place a cell there, including buffers from `repair_design`/`repair_timing` and CTS.
- Generic over the floorplan: macros are found from the database, not from a hand-kept list, so either ring floorplan and any future macro move are covered.
- Each report figure checked against the numbers already measured on run `38094932339` before any lane run. Reproducing them is the test.

**Non-Goals:**
- Touching the pad-ring band itself (for example routing blockages outside the core). With no cells trapped behind macros there should be little reason to route there. The guide count (spec) shows whether that holds.
- Any change to macro positions, `floorPadding*`, `cut_rows` arguments or `addHaloToBlock`.

## Decisions

### D1. Hard placement blockages over each margin, created after the last macro is placed

A new helper, `block_macro_core_margins {max_gap}` in `floorplan_util.tcl`, works as follows:

1. Walk the block's instances whose master is a `BLOCK`.
2. For each of the four sides, measure the distance from the macro's bounding box to the matching core edge.
3. Where that distance is greater than 0 and no greater than `max_gap`, create a **hard** placement blockage (`odb::dbBlockage_create`, not `setSoft`) covering the gap along the full length of that side.
4. Where two adjacent sides both qualify, also block the corner square between the macro's corner and the core's corner.
5. Log one line per blockage and a total.

The corner step was added after probe run `38359120738`: with only the side blockages, the corner square north-east of LLC tag 3 stayed open but enclosed (the east blockage to the south, the north blockage to the west, the core edges), and `cts` failed on the one cell placed there once padding had used up the space around it. The box geometry lives in `macro_core_margin_boxes`, which the report proc (D3) also uses.

Both ring floorplans call the helper as their last step, after every macro is placed. That includes the two hyperbus delay lines: they are `CLASS BLOCK` too (39.8 × 41.6 µm), and the 4-way floorplan places them 8.00 µm off the west core edge **after** its last `cut_rows`, on purpose, because they sit on rows like multi-row cells. Calling the helper before that `cut_rows` would miss them.

A hard blockage is honoured by global placement, by both legalizers and by the resizer's placement of inserted buffers, so it meets the spec on its own. The rows under it are therefore not cut. They stay, empty, with their Metal1 followpins, and the power grid is unchanged.

(Revised during implementation: the plan was to call the helper before the last `cut_rows` and let it cut the rows too, which would have missed the delay lines.)

Alternatives:
- **Set `floorPadding*` to 0 so macros abut the core edge.** Rejected: it moves every macro, changes how the macro power rings meet the core ring, and mixes a macro move into the measurement.
- **Soft blockage.** Rejected: soft blockages only steer global placement, so legalization and repair could still put cells there.
- **Delete and split the rows directly in odb.** Rejected: more code for the same effect as a hard blockage, and it would bypass `cut_rows`' own handling of the row ends.
- **A fence region per macro.** Rejected: far more machinery than the problem needs.

### D2. One setting, `pnr_macro_margin_max`, default 20 µm

`pnr_macro_margin_max` lives in `common.tcl`, with `PNR_MACRO_MARGIN_MAX` as its override. A value of 0 turns the blocking off, and the floorplan logs `Macro margin blocking: off`.

Why 20 µm:
- It covers all four measured gaps (8.0 and 14.0 µm) with margin to spare.
- It stays below the narrowest intended routing channel next to a core edge. The floorplan's macro-to-macro channels are 15–30 µm, but the helper only ever measures distance to the **core** edge, never between macros, so it cannot block a channel.
- At a larger die scale the gaps keep their size, because `floorPadding*` is absolute. So one default serves every `die_scale`.

### D3. Margin and channel counts from `dpl.tcl`, surfaced by `run_pnr.sh`

In `dpl.tcl`, just before the gated legality check (so the counts exist when it fails), a `common.tcl` proc counts placed standard cells:
- **in the margins**: the same geometry as D1, recomputed from the macros and the core area so the count works even when blocking is off;
- **in narrow channels**: between two macros that face each other across a gap no wider than `pnr_macro_channel_max` (default 40 µm, override `PNR_MACRO_CHANNEL_MAX`), along the length both macros share.

The proc logs `Macro margins: <n> cells (gap <= <w> um)` and `Macro channels: <n> cells (gap <= <w> um)`. `report_placement_state` greps both lines into the placement report and raises `::warning::` when the margin count is non-zero. Lines missing from the log (for example after a `dpl` timeout) are reported as "not reported", like the existing fields.

The 40 µm channel width catches the 30 µm stacked-SRAM channels. On run `38094932339`'s `grt` checkpoint the proc counts 6,308 margin and 5,976 channel cells in 44 s (task 2.3), matching an independent count from the DEF.

Alternative: compute the counts in `run_pnr.sh` from a DEF. Rejected: stage checkpoints hold the DEF only inside a zip, and Tcl in the stage process already has the database open.

### D4. Guide count with `awk` in `run_pnr.sh` after `grt`

`grt.tcl` logs the core area in database units (`Core area (dbu): x0 y0 x1 y1`). After the `grt` stage, `run_pnr.sh` streams `${REPORTS}/${PROJ_NAME}_route.guide` through `awk`: it counts nets with at least one guide rectangle whose centre lies outside the core, and prints `Nets routed outside the core: <n>`. If the guide file or the core-area line is missing, it prints `not computed` with the reason. It never changes the exit status.

Alternative: iterate `dbNet` guides in Tcl inside `grt.tcl`. Rejected: about 1 M nets × several guides is slow in Tcl, and it would delay the stage checkpoint for a report. `awk` streams the 500 MB file in about a minute.

On the old guide file, with the snapped core area `grt.tcl` logs, the count is 9,313. (The exploration's probe found 8,259 because it used the unsnapped 380 / 380 / 6397 / 5570 µm.)

### D5. No new dispatch input

`pnr.yml` has 9 of GitHub's 10 `workflow_dispatch` inputs, and the A/B baseline already exists (run `38094932339`, made without blocking). Reproducing the old floorplan therefore needs no lane input. `PNR_MACRO_MARGIN_MAX=0` serves local runs, and a later change can spend the last input if a lane A/B is ever needed. CI behaviour and the `ci-pipeline` spec are unchanged.

### D6. Validation: one lane run to `grt`, judged against `38094932339`

Run A is a full flow at default settings, `stop_after=grt`, on a ref whose synth key matches `38094932339`. It compares, against `38094932339`:

| figure | baseline | expect |
|---|---|---|
| cells in margins | 6,308 | 0 |
| cells in narrow channels | 5,976 | similar (not targeted) |
| nets routed outside the core | 9,313 | far fewer |
| `grt` overflowing edges (total, per layer), max H/V | 198,046; 30/29 | lower |
| `grt` demand / Metal3 | 65.9 % / 78.7 % | about the same |
| WNS / TNS at `grt` | −13.12 ns / −116 k ns | no worse |
| max slew / max cap violations at `grt` | 4,293 / 1,914 | no worse |
| `gpl`/`dpl`/`cts`/`grt` runtimes | the run's | about the same |

Success is the first three rows moving as expected with the timing rows no worse. A lower overflow count is the result being measured, not a pass/fail gate: if it does not drop, that finding goes into Phase 11 and the change still stands on the first three rows.

Run B (optional, the user's call after A) resumes from A's `grt` checkpoint, runs `drt` with the lane's 5 iterations (about 15.5 h) and compares violations per layer against run `38178131540`.

### D7. Routability inflation 2.5 in both global-placement passes

The outcome of D6 forced this. Run A (margins blocked, everything else unchanged) emptied the margins and improved timing, but tripled `grt` overflow. The attribution run (D6, task 4.1) showed the flow is deterministic, so the blocking itself caused it. About 5,400 displaced cells went into the north-east corner, where the SPI host already made the densest area of the die.

Two levers were tried:
- **Padding the SPI host's cells at legalization** (probe `38359120738`). It failed in `cts`: legalization can only move cells a short way, and the corner had no room left (task 5.1).
- **Letting global placement inflate congested cells harder** (probe B, `38395368038`). `gpl.tcl` carried upstream's 2024 tuning, `-routability_inflation_ratio_coef 1.2 -routability_max_inflation_ratio 1.2`, which caps inflation at ×1.2. In every run on record, routability mode added about 1 % area per iteration and ended at "could not reach target". At 2.5 in both passes, overflow fell to 74,776 edges (−62 % against the baseline), WNS at `grt` to −8.96 ns, and slew/cap violations and power fell below the baseline. Repair then inserts far less (`GPL-1014` +34 % instead of +56 %).

2.5 is not a fitted value: it was chosen as a clearly stronger round number, believed to match OpenROAD's historical default (not verified for this build, whose defaults are compiled in). No sweep was run. Alternatives:
- **A higher value or a sweep.** Not done: each point is a 6 h lane run, and 2.5 already turned the result.
- **`-routability_use_grt`** (FastRoute instead of RUDY for the congestion estimate). Not tried: one global route takes about 2 h here, and routability mode runs 15 or more iterations.
- **Shipping the margin blocking alone.** Rejected: it makes routing worse.

The gain is not split between D1 and D7: inflation 2.5 without margin blocking was not run. What is shown is that D1 alone hurts and D1 with D7 helps on every figure but TNS and the count of setup-violating endpoints, which are better than the baseline but worse than with D1 alone.

## Risks / Trade-offs

- **[The hotspot only moves.]** Cells pushed out of the east margin land next to the macro column. The column's gaps may still funnel traffic. → The guide count and per-layer overflow show it. The channel count (D3) is the next lever, in its own change.
- **[A placement step ignores the blockage.]** → Task 1.3 checks the blockages on the real floorplan checkpoint. After a run, the margin count (D3) shows any cell that got in anyway. The `dpl`/`cts` legality gates are unaffected.
- **[Utilization rises slightly.]** About 0.15 mm² blocked of a 31 mm² core (≈ 0.5 %). → Negligible at the current 56–59 % utilization. `DPL-0009` in the run reports it.
- **[The awk guide count is too slow or memory-hungry on the VM.]** → It streams, holding only the current net, and runs once per run after `grt`. Task 3.2 times it on the real 500 MB file.
- **[The SPI host corner remains the hotspot.]** It holds about 76 % of the remaining sampled overflow in probe B, at far lower totals. → The next lever if routing needs more headroom, in its own change.
- **[Comparability.]** Figures before and after are from different placements. → Proposal marks this BREAKING. The thesis requote decision (Phase 11) must re-run both sides.

## Migration Plan

Merge to `main` after task 4.1 (run A) has shown the margins empty. Old checkpoints cannot be resumed into a run with this change. `run_pnr.sh`'s synth-key guard does not catch that, because the netlist is unchanged, so `docs/pnr-pipeline.md` says so next to `die_scale`'s identical caveat. Rollback is `PNR_MACRO_MARGIN_MAX=0` locally, or a revert.

## Open Questions

- North-side margin cell count on the baseline: not measured by the probe (it checked east, west and south). Task 2.3 measures it on the baseline checkpoint.
