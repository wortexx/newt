# Tasks

Tags:

- **[edit]** plain editing, checked with cheap local validation: `openspec validate`, short OpenROAD calls in the `newt-eda:dev` image.
- **[eda]** loads a checkpoint in the image locally, minutes under emulation. Re-running `pdngen` adds about 15 minutes.
- **[probe]** the scratch KLayout DRC probe (`drc-probe-klayout` image, `stream.py`, `sg13g2_batch.drc`, `sweep.sh`/`merge.py`). It runs locally, in minutes for a window and about 5 h for the full die. Not part of the repo.
- **[long-run]** a P&R lane dispatch on the VM, about 12 h. Always ask the user first.

The local checkpoint is run `44382400639`'s `basilisk.power_grid`, fetched from the `pnr-checkpoints` container the way `pnr.yml`'s "Download checkpoints from Blob" step does. It has the macros placed and the grid built, but no standard cells. So the abutment items at the delay lines can only be checked on the measured run's final DEF (task 3.2).

## 1. Delay lines on the site grid (design D1, D3)

- [x] 1.1 **[edit]** Add two procs to `floorplan_util.tcl`:
  - one that rounds an x in microns up to the site grid of the rows, reading the origin and site width from the database;
  - one that checks every `delay_line_D4_O1_6P000` instance's origin against the site grid and the row grid, logs each position, and errors naming the instance and position when it is off either grid.

  Use the first for `X` in the delay-line block of `floorplan_ring_2way.tcl` and `floorplan_ring_4way.tcl`, and call the second right after the two `placeInstance` calls, inside the same `HYPER_CONF` guard. Update the block's comment to say why x is rounded. Verify with `git diff` that nothing else in either floorplan changes, and that the SRAM placement still uses the unrounded `floor_leftX`.
- [x] 1.2 **[eda]** Verify on the local checkpoint, sourcing `floorplan_util.tcl`:
  - the rounding proc maps 388.16 to 388.32 and leaves 388.32 unchanged;
  - after moving both delay lines with it, the check logs x 388.32 and the existing y values (4093.74 and 4139.1) and passes;
  - setting one instance back to 388.16 makes the check error with that instance's name;
  - with `pdngen -ripup` and `power_grid_stripes.tcl` re-sourced after the move, the log has `Delay-line rail bridges: 48`, all bridges are shorter than 1 µm, and both `Power grid check` lines read `clean`.

  Done 2026-11-20 on run `44382400639`'s `basilisk.floorplan`, the checkpoint taken before the grid exists. The grid is not built yet there, so `power_grid_stripes.tcl` was sourced as is, not after `pdngen -ripup`. The checkpoint's instances are FIRM, so the probe set them PLACED before moving them.
  - The rounding maps 388.16 → 388.32, 388.32 → 388.32 and 380.16 → 380.16.
  - Before the move, the check errors on the tx delay line at 388.16. The message gives the 0.48 µm site grid in line with the rows at x 380.16.
  - After the move, it logs both at x 388.32 (y 4139.1 and 4093.74) and `Delay lines on the site grid: 2`.
  - The grid build logs `Delay-line rail bridges: 48`, all 0.44 µm long at x 387.88–388.32 and 428.16–428.6, then `Same-net TopMetal1 gaps filled: 12` and both nets `clean`. pdngen took 634 s under emulation.

## 2. Same-net TopMetal1 gap fill (design D2, D3)

- [x] 2.1 **[edit]** Add `scripts/pdn_fill_gaps.tcl` (SHL-0.51 header, newt copyright line as in `pdn_repair_straps.tcl`) with `pdn_fill_same_net_gaps {layer}` per D2. Source it and call it for `TopMetal1` in `power_grid_stripes.tcl` after the repair-strap block and before `pdn_check_grid`, with a comment pointing to this change. Verify with `git diff` that the `pdngen` call and everything before it are unchanged.
- [x] 2.2 **[eda]** Verify on the local checkpoint, which already has the grid (no `pdngen` re-run needed):
  - the call logs `Same-net TopMetal1 gaps filled: 12`;
  - the 12 new boxes span x 404.17–412.15, 469.95–477.93, 7106.99–7114.97 or 7172.77–7180.75;
  - their y ranges are exactly the gaps the DRC reported: 1631.75–1632.01, 2243.23–2244.37 and 2858.63–2859.41 on the west column, and 1185.41–1185.97, 1989.23–1989.59 and 6265.95–6266.29 on the east;
  - `pdn_check_grid` stays clean;
  - a second call adds 0;
  - after adding a 0.2 µm VSS TopMetal1 box inside one VDD gap, the call errors naming both nets and the location, and adds nothing.

  Done 2026-11-20 on run `44382400639`'s `basilisk.power_grid`:
  - `Same-net TopMetal1 gaps filled: 12`, all VDD, in 19 s under emulation;
  - the 12 boxes are exactly the expected x spans and DRC y ranges;
  - both nets `clean`, and a second call filled 0;
  - with a VSS box at x 472–474, y 2243.7–2243.9, the call errored with "TopMetal1 gap fill on VDD would touch VSS at x 469.95-477.93 y 2243.23-2244.37 um", and the VDD box count stayed at 276,018.

  The first version filled each gap 4 times, once per pair of DRCFILL pad and via boxes ending at its edges. The proc now keeps only the widest fill of overlapping candidates.
- [x] 2.3 **[probe]** `write_def` from the checkpoint after 1.2 and 2.2. Stream it with the probe's `stream.py` and run the deck on two windows: the west SRAM column (x 380–520, y 800–4100) and the delay lines (x 370–445, y 4075–4200). Verify 0 `TM1.b` and 0 `M1.b` in both, which also covers the bridges at their new length. Other items must be only IP-internal or clip-edge, and match the 2026-11-20 baseline windows.

  Done 2026-11-20 on the DEF written after 1.2, which has the grid, the fills and the moved delay lines, but no standard cells yet.
  - Delay-line window: 0 `TM1.b`, 0 `M1.b`. The rest is the delay line's own Passiv, PEmWind and `M2.a` (996 + 902 + 316 + 388, the same as the baseline), plus clip-edge items at x 370 and y 4075/4200.
  - West SRAM column: 0 `TM1.b` (the baseline had 6), 0 `M1.b`. The rest is the SRAMs' bar-contact `Cnt.a`, the delay line's edge of the window, and clip-edge items at x 520 and y 4100.

  The abutment rules at the delay lines (`Cnt.a`, `Cnt.b`, `Act.b` against cells) need placed cells, so they stay with task 3.2.
- [x] 2.4 **[edit]** Document the snap, the fill, their log lines and failure messages in `docs/pnr-pipeline.md`'s floorplan stage row. Verify that the docs name the same log lines as the code.
- [x] 2.5 **[edit]** Verify `openspec validate snap-delay-lines-and-fill-tm1-gaps --strict` passes. Open the PR with groups 1–2 and the change artifacts. After the user merges, the measured run dispatches on `main`.

## 3. Measured run (proposal: Measured run)

- [x] 3.1 **[long-run]** *(ask the user first)* Dispatch the P&R lane on `main` with every input empty and no resume. Save `pnr-reports` under `target/ihp13/openroad/out/ci-<run>/`, and fetch the final DEF into the scratchpad. Verify the floorplan log has:
  - both delay-line positions at x 388.32;
  - `Delay-line rail bridges: 48`;
  - `Same-net TopMetal1 gaps filled: 12`;
  - both `Power grid check <net>: clean` lines.

  Also verify `drt ok` and `final ok`.

  Done: run `44708127322` on `main` (`7cbb578`), 2026-11-20 09:07 to 2026-11-21 12:47 UTC. Both delay lines at x 388.32 (y 4139.1 and 4093.74), `Delay lines on the site grid: 2`, 48 bridges, 12 fills, both nets `clean`. `drt ok` (iteration 28, 120 markers) and `final ok`. Reports in `out/ci-44708127322/`.
- [x] 3.2 **[probe]** Stream the final DEF and run the full-die sweep, or at least the delay-line window and both SRAM columns. Then run `merge.py` with macro tags. Verify:
  - 0 `Cnt.a`, `Cnt.b`, `Act.b` and `M1.b` outside the SRAM boxes, other than delay-line-internal shapes;
  - 0 `TM1.b`;
  - no new rule or location compared with the 2026-11-20 sweep of `44382400639`.

  Done 2026-11-21: full die, 56 tiles of 1 mm, all rc 0, 7 h 19 m.
  - **Targets met.** 0 `Cnt.b`, `Act.b`, `M1.b` and `TM1.b`. All 1,183,332 `Cnt.a` are inside SRAM boxes, the same count as the baseline. The delay line's own `Pas.a`/`Pas.b`/`M2.a`/`forbidden.PEmWind` are unchanged (996/902/388/316).
  - **Exception: new rules.** 24 `M2.b`, 3 `M3.b` and 5 `M5.b`, all 32 within 1 µm of a marker in the run's `basilisk_route_drc.rpt` on the same layer. They are the router's own leftover markers (120 in this run, 5 in the baseline), from the different placement (see 3.3), not geometry this change adds.
  - **Merge script.** The `merge.py` recovered after the scratchpad was cleared took every tile as 2 mm wide, so it also counted clip-edge artefacts from neighbouring tiles' margins (22 rules). The counts above use `merge2.py`, which reads the tile size from the file name. It reproduces the baseline's SRAM count exactly, so the 2026-11-20 merge used the same extent. The probe files are kept in `target/ihp13/openroad/out/drc-probe/` (git-ignored).
- [x] 3.3 **[edit]** Compare with `44382400639`:
  - WNS, TNS, area and power from `pnr-reports`;
  - drt markers and antenna counts.

  Record the full-die DRC baseline of 2026-11-20 and this run's result in a new `docs/infra-plan.md` record, with:
  - the probe setup: the image, the deck generator, the GDS merge with renamed sub-cells, and the tile sweep;
  - the classification table;
  - the waiver list for IP items.

  Verify that the record's numbers match the probe's merged output and the run's reports.

  Done 2026-11-21: record "First signoff DRC, and the delay lines on the site grid" in `docs/infra-plan.md` Phase 11.
  - The DRC numbers are from `merge2.py`'s output, and the IP total (1,185,934) is the sum of the waiver-list rules.
  - The PPA numbers are from `basilisk.grt.rpt`, `pnr_grt.log`, `pnr_status.log` and the timestamped `pnr_drt.log` of both runs.
  - The PPA moved beyond run-to-run drift (clock power 0.373 → 0.668 W, area +3 %, WNS −1.15 ns) because CTS built the register tree two levels deeper. The cause and the follow-up change `stabilize-cts-tree-depth` are in the record. `44382400639` stays the PPA reference until that change lands, as the proposal's Impact allows ("the drift is recorded").

## Workflow follow-up

- Archive the change after the measured run is recorded and the user has merged the record.
