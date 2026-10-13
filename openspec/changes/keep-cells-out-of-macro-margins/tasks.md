# Keep cells out of macro margins (change `keep-cells-out-of-macro-margins`) — tasks

Tags:

- **[edit]**: plain file editing, checked locally (`tclsh` parse of the scripts, `bash -n`,
  `shellcheck`, the driver's `PNR_DRY_RUN=1` mode).
- **[eda]**: needs OpenROAD from `ghcr.io/wortexx/newt-eda:dev` (same build, `2c56926`, as the
  lane), run locally against run `38094932339`'s checkpoints from the `pnr-checkpoints` blob
  container. Minutes to an hour under amd64 emulation; the local Docker VM has 19.5 GB.
- **[long-run]**: a P&R lane run on the self-hosted Azure VM (hours). Each one is dispatched
  **only after the user approves it**, never as a speculative check.

Baseline numbers to reproduce come from the exploration on run `38094932339` (proposal.md
table): 6,308 margin cells (2,200 / 1,748 / 1,681 / 679 east / north / south / west), 5,976
cells in channels ≤ 40 µm, 9,313 nets with guides outside the core. (The exploration first
quoted 2,627 and 3,439: its DEF parser skipped every cell carrying `+ SOURCE TIMING`, i.e. all
buffers and tie cells inserted by repair and CTS; and 8,259 nets, measured against the
unsnapped core edge. Tasks 2.3 and 4.1 found and corrected both.)

## 1. Margin blocking in the floorplan (design D1, D2)

- [x] 1.1 **[edit]** In `scripts/pnr/common.tcl`, define `pnr_macro_margin_max`:
  - Read it from `PNR_MACRO_MARGIN_MAX`; an empty or unset value means `20` (µm).
  - Reject a negative or non-numeric value with a Tcl `error`.
  - Comment it in the file's existing style, citing this change and Phase 11.

  Verify: the `tclsh` parse check passes.
- [x] 1.2 **[edit]** Add `block_macro_core_margins {max_gap}` to `floorplan_util.tcl` (design D1):
  - For every instance whose master type is `BLOCK`, on each of its four sides, create a hard
    `odb::dbBlockage` over the gap to the core edge when `0 < gap <= max_gap`, spanning the
    side's full length.
  - Log one line per blockage (instance, side, gap in µm) and a total.
  - With `max_gap` 0, create nothing and log `Macro margin blocking: off`.

  Call it in `floorplan_ring_4way.tcl` and `floorplan_ring_2way.tcl` with
  `$pnr_macro_margin_max` as each file's last step, after every macro (delay lines included) is
  placed (design D1). Verify: `tclsh` parse; by reading, nothing is placed after the call in
  either file and no other `floorplan_*.tcl` changed.
- [x] 1.3 **[eda]** Run the helper on the real floorplan. Download `38094932339/basilisk.floorplan.zip`,
  load it in `newt-eda:dev` with the stage's own `pnr_load`, and run
  `block_macro_core_margins 20`. Verify:
  - blockages exist on exactly the east, west, south and north margins (gaps 8.00 east/west,
    14.00 µm south/north) plus the delay lines' west side, and none between two macros;
  - each blockage is hard (`isSoft` false) and overlaps placement rows, i.e. it really covers
    sites the placer could otherwise use;
  - with `0`, no blockage is created and the log says `off`.
- [x] 1.4 **[edit]** Document `PNR_MACRO_MARGIN_MAX` in `run_pnr.sh`'s header next to
  `PNR_DIE_SCALE`, and in `docs/pnr-pipeline.md`'s `floorplan` row. Note there that a run with
  this change cannot resume from older checkpoints, which the synth-key guard does not catch.
  Verify: `bash -n run_pnr.sh`; the doc row names the setting, its default and the resume caveat.

## 2. Placement report: margin and channel counts (design D3)

- [x] 2.1 **[edit]** Next to `pnr_macro_margin_max` in `common.tcl`, add `pnr_macro_channel_max`
  (`PNR_MACRO_CHANNEL_MAX`, default `40`, same validation). Add `pnr_report_macro_margins`, which logs
  `Macro margins: <n> cells (gap <= <w> um)` and `Macro channels: <n> cells (gap <= <w> um)`,
  computed from macro and core geometry, so it works with blocking off. Call it in `dpl.tcl`
  just before the gated legality check (so the counts exist when that check fails), inside the
  stage's `catch` but not able to fail the stage: wrap it in its own `catch` that logs an error
  line instead. Verify: `tclsh` parse; by reading,
  a failure in the report cannot change `dpl`'s status.
- [x] 2.2 **[edit]** Extend `run_pnr.sh`'s `report_placement_state` with both counts. Print
  `not reported` when a line is missing, and raise
  `::warning::Cells placed in macro margins: <n> …` when the margin count is non-zero. Verify:
  `bash -n`, `shellcheck`, and the function run against a hand-made `pnr_dpl.log` holding each of
  three cases (zero, non-zero, missing) prints the expected line and warning.
- [x] 2.3 **[eda]** Run `pnr_report_macro_margins` on run `38094932339`'s `grt` checkpoint
  (`38094932339/basilisk.grt.zip` from the blob container) with blocking off. Verify the counts
  against an independent count from the checkpoint's DEF and record the runtime.
  — done. The proc logs `Macro margins: 6308 cells (gap <= 20 um)` and
  `Macro channels: 5976 cells (gap <= 40 um)` in 44 s. A Python count over the DEF, using the
  same rule (cell centre inside a margin or channel box), gives exactly 6,308 and 5,976. The
  margin cells split 2,200 east, 1,748 north, 1,681 south, 679 west; 3,355 of them are
  buffers and tie cells inserted by repair and CTS (`+ SOURCE TIMING`), e.g. 803 `buf_16` and
  1,359 tie cells. The exploration's 2,627 / 3,439 came from a DEF regex that skipped every
  component carrying `+ SOURCE TIMING` before `+ PLACED`, so it missed all inserted cells; the
  proposal, design and comments now carry the corrected figures.

## 3. Global-routing report: nets outside the core (design D4)

- [x] 3.1 **[edit]** In `grt.tcl`, log `Core area (dbu): x0 y0 x1 y1` after loading the
  checkpoint. In `run_pnr.sh`, after the `grt` stage (whatever its result), stream
  `${REPORTS}/${PROJ_NAME}_route.guide` through `awk`. Count nets with at least one guide whose
  centre lies outside the core, and print `Nets routed outside the core: <n>`. Print
  `not computed (<reason>)` when the guide file or the core-area line is missing. Never change
  the exit status. Verify: `bash -n`, `shellcheck`; by reading, the step sits outside the gate
  logic.
- [x] 3.2 **[edit]** Check the `awk` count against the baseline: run it on run
  `38094932339`'s `basilisk_route.guide` (`pnr-reports` artifact of that run, `gh run download 38094932339 -n pnr-reports`) with
  that run's core area. Verify: it reproduces the exploration's count. (It printed 8,259 with
  the unsnapped core 380000 380000 6397000 5570000; with the snapped core `grt.tcl` logs,
  380160 381780 6396960 5567940, the correct figure is 9,313 — found in task 4.1.) Record its
  wall time and peak memory (`/usr/bin/time -l`). A missing-file run prints `not computed`.
- [x] 3.3 **[edit]** Add the two report lines (placement counts, nets outside the core) to
  `docs/pnr-pipeline.md` next to the existing placement-report paragraph. Verify: the documented
  line formats match what 2.2 and 3.1 print.

## 4. Validation on the lane (design D6)

- [x] 4.1 **[long-run]** *(needs the user's approval before dispatch)* Run A: full flow, default
  settings, `stop_after=grt`, on a ref whose synth key matches run `38094932339`. Verify:
  - the placement report shows 0 cells in the margins and no margin warning;
  - `dpl` and `cts` legality checks pass;
  - record every figure in design D6's table against the baseline: channel count, nets outside
    the core, `grt` overflow (total, per layer, max H/V), demand and Metal3, WNS/TNS, slew/cap
    counts, `DPL-0009` utilization, stage runtimes.
  — done: run `38254112819` (`3c40d7b`, synth cache hit, so the same netlist as the baseline).
  Every gated stage passed. 33 blockages; margins 0 cells, no warning; `dpl` and `cts` legal.

  | figure | baseline `38094932339` | run A `38254112819` |
  |---|---:|---:|
  | cells in margins | 6,308 | **0** |
  | cells in channels ≤ 40 µm | 5,976 | 6,277 |
  | nets routed outside the core | 9,313 | **5,210** (−44 %) |
  | `grt` overflowing edges | 198,046 | **603,825** (×3.0) |
  | max overflow H / V | 30 / 29 | 58 / 66 |
  | per layer M2 / M3 / M4 / M5 / TM1 | 32 k / 47 k / 67 k / 41 k / 11 k | 151 k / 173 k / 162 k / 99 k / 19 k |
  | demand (total) / Metal3 | 65.9 % / 78.7 % | 65.3 % / 81.5 % |
  | WNS / TNS at `grt` | −13.12 ns / −116.1 k ns | **−9.31 ns / −75.1 k ns** |
  | setup / hold violating endpoints | 42,999 / 316 | 22,592 / 375 |
  | max slew / max cap violations | 4,293 / 1,914 | 4,859 / 2,093 |
  | WNS after `cts` | −4.07 ns | −3.60 ns |
  | `DPL-0009` / `GPL-1014` | 56.2 % / +56.19 % | 56.2 % / +57.45 % |
  | `gpl` / `dpl` / `cts` / `grt` | 2 h 33 / 5 m / 34 m / 2 h 10 | 2 h 24 / 5 m / 60 m / 2 h 32 |

  Sampled overflow (congestion report, 10 k edges per direction) moved: over macros 15.8 k →
  13.7 k and near-zero-capacity edges 7,609 → 5,943, but a north-east hotspot around the SPI
  host (x 5.4–6.8 mm, y 4.2–6.0 mm) grew from about 10 k to 58 k. The SPI host sits there in
  both runs; in run A it is about 190 µm further south and the area is slightly denser
  (250 µm tiles above 75 % cell density: 69 → 88).

  Attribution run `38322276116` (branch `margin-blocking-off-probe`: run A's commit with the
  default margin width set to 0, same cached netlist) reproduced the baseline exactly: the same
  guide file byte for byte, 198,046 overflowing edges, WNS −13.12 ns, TNS −116,071.70 ns, the
  same slew/cap counts and `GPL-1014` area. The flow is deterministic, so every difference
  between the baseline and run A comes from the margin blocking: the timing gain and the
  ×3 overflow alike. With blocking off, `dpl` counts 5,428 margin cells (6,308 at `grt`, after
  CTS adds buffers).

- [ ] 4.2 **[edit]** Record run A in `docs/infra-plan.md` Phase 11:
  - a new dated finding with the diagnosis (proposal table) and run A's before/after table;
  - the `addHaloToBlock` no-op as a recorded finding;
  - tick or reword the Phase 11 lever list to match.

  Verify: the figures match run A's reports, and the "relax our own layer adjustments" lever
  carries the caveat from this exploration (it moves demand onto Metal2, where half the DRC
  violations are).
- [ ] 4.3 **[long-run]** *(optional; the user's call after 4.1)* Run B: `resume_from_run=<A>`, no
  `resume_exclude` (`grt_repair` is skipped and only re-saves `grt` as `grt_repaired`), the
  lane's 5 `drt` iterations. Compare violations per
  layer and type against run `38178131540`'s iterations 0–2, and record them in Phase 11.
  Verify: the comparison table is in Phase 11, or the task is marked skipped with the user's
  decision.
