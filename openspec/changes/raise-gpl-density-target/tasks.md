# Converge global placement (change `raise-gpl-density-target`) — tasks

Tags:

- **[edit]**: plain file editing, checked locally (`bash -n`, `shellcheck`, the driver's
  `PNR_DRY_RUN=1` mode).
- **[long-run]**: a P&R lane run on the self-hosted Azure VM (≥ 10 h full). Each one is
  dispatched **only after the user approves it**, never as a speculative check.

Groups 1–3 are the first plan (density 0.72) and its measured result, kept as the record.
Groups 5–7 are the revised plan (design D1–D4, 2026-10-03).

## 1. Density target, in one place (first plan)

- [x] 1.1 **[edit]** Define the density once in `scripts/pnr/common.tcl` as `pnr_gpl_density`
  (`PNR_GPL_DENSITY` override), used by both passes in `gpl.tcl`, which logs it. — done; the
  default is now 0.65 again (5.1).
- [x] 1.2 **[edit]** Same value in `scripts/chip.tcl`. — done; now 0.65 again (5.1).
- [x] 1.3 **[edit]** `pnr.yml` `workflow_dispatch` input `gpl_density` → `PNR_GPL_DENSITY`. —
  done. `gh workflow view pnr.yml --ref raise-gpl-density-target --yaml` shows the input and its
  plumbing.

## 2. Headroom warning (first plan, superseded by 5.3)

- [x] 2.1 **[edit]** Post-`dpl` check of `DPL-0009` against the density target. — done, then
  replaced by the placement report (5.3): its premise was disproved by 3.2.
- [x] 2.2 **[edit]** Documented in `docs/pnr-pipeline.md`. — done, rewritten in 5.4.

## 3. Measure the first plan

- [x] 3.1 **[edit]** Find a surviving `pre_place` checkpoint on the current netlist. — done:
  **none exists**. No P&R run has started since the Cheshire v0.3.1 bump (#48) changed the
  netlist, and the synth-key identity guard refuses a mismatched checkpoint.
- [x] 3.2 **[long-run]** Dispatch at 0.72, `stop_after=cts`; if `dpl` or `cts` times out, stop
  and report. — **run `37037836332` (2026-10-02, `75dd68e`, full flow): `dpl` timed out (exit
  124 at 7,200 s). Stopped and reported; the user chose the revised plan (groups 5–7).**

  | | 34938462965 (09-15, ok) | 36188933699 (09-26, 0.65) | 37037836332 (0.72) |
  |---|---:|---:|---:|
  | `DPL-0009` utilization | 62.9 % | 66.1 % | 67.3 % |
  | pass 2 timing-driven `repair_design` area (`GPL-0107`) | +6.85 % | +4.79 % | +6.11 % |
  | target after it (`GPL-0110`) | 0.895 | 0.993 | 1.043 |
  | pass 2 reverted to overflow (`GPL-0999`) | 0.189 | 0.218 | 0.217 |
  | final placement area (`GPL-1014`) | +29.5 % | +51.7 % | +59.4 % |
  | illegal cells, legalizer iteration 0 | 82,811 | 203,229 | 223,074 |
  | illegal cells, iteration 570 | — | 26,386 | 34,939 |

  The `-density` value only sets the starting target. Routability inflation is reverted by
  `gpl` itself (`GPL-0055`). The damage is pass 2's second timing-driven iteration: a real
  `repair_design` at overflow ≈ 0.2 adds 0.9–1.2 mm² of buffers, the target jumps, Nesterov
  diverges, and `gpl` reverts to an unconverged snapshot. The good run went the same way, with
  a smaller jump. A higher starting density makes the jump bigger.

## 4. (Replaced by groups 5–7)

The first plan's merge and reference tasks are superseded by 6.x and 7.x.

## 5. Revised settings

- [x] 5.1 **[edit]** `common.tcl`: `pnr_gpl_density` default `0.65`; new `pnr_gpl_keep_resize`
  (`PNR_GPL_KEEP_RESIZE`, default `0`). `gpl.tcl` passes `-keep_resize_below_overflow
  $pnr_gpl_keep_resize` to pass 2 only, and logs both values. `chip.tcl` uses the same values.
  Verify that `grep -rn "density 0.72" target/ihp13/openroad/scripts/` returns nothing, and that
  pass 1's arguments are unchanged.
- [x] 5.2 **[edit]** `run_pnr.sh`: `STAGE_TIMEOUT_DEFAULT` `dpl` 14400, `cts` 28800; header
  documents `PNR_GPL_KEEP_RESIZE`. `pnr.yml`: input `gpl_keep_resize` → `PNR_GPL_KEEP_RESIZE`.
  Verify `bash -n`, and that `PNR_DRY_RUN=1` (in the tooling image) lists `dpl` at 14400 s and
  `cts` at 28800 s, and that the workflow YAML parses with five dispatch inputs. — done: dry run
  shows `dpl` 14400 s and `cts` 28800 s; `yaml.safe_load` lists `resume_from_run`,
  `resume_exclude`, `stop_after`, `gpl_density`, `gpl_keep_resize`.
- [x] 5.3 **[edit]** Replace the headroom check with `report_placement_state` (design D2).
  Verify it against the three runs' `pnr_gpl.log`/`pnr_dpl.log` (each must warn, naming its
  revert overflow and iteration-0 illegal cells) and against a missing log (prints "not
  reported", no warning). — done: 34938462965 warns (0.189, 82,811), 36188933699 (0.218,
  203,229), 37037836332 (0.217, 223,074); a missing log prints "not reported".
- [x] 5.4 **[edit]** `docs/pnr-pipeline.md`: dispatch inputs (five), the `gpl` row, the
  placement report replacing the headroom paragraph, the per-stage timeouts. `docs/infra-plan.md`
  Phase 11: the corrected diagnosis and the revised action. Verify that neither file still
  presents 0.72 as the default or the headroom premise as the cause.

## 5b. Larger die (design D5)

- [x] 5.5 **[edit]** `common.tcl`: `pnr_die_scale` (`PNR_DIE_SCALE`; default `1.10`, then `1.0` since 2026-10-04, after 6.1). Both
  `floorplan_ring_*way.tcl` scale the core's width and height and keep the 380 µm margins, rounding
  the die to whole microns. `chip.tcl` sets the same default. `pnr.yml` input `die_scale`;
  `run_pnr.sh` header; `docs/pnr-pipeline.md` inputs and floorplan row. Verify that the floorplan
  scripts parse, and that scale 1.0 gives exactly 6230 × 5478 µm and 1.10 gives 6777 × 5950 µm
  (core 31.2 mm²). — done (`tclsh` arithmetic check; all edited Tcl files are `info complete`).

## 6. Measure the revised plan

- [x] 6.1 **[long-run]** Ask the user, then dispatch `pnr.yml` on this change's branch, full flow
  (no checkpoint matches; 3.1), `stop_after=grt`. In progress: run `37108127061` (`dff4df0`,
  D1 only, taped-out die); 6.2 replaces it if it fails. Record in Phase 11, next to the 3.2
  table:
  - pass 2 convergence (the placement report line);
  - illegal cells at iteration 0;
  - `dpl` and `cts` runtimes, against both the old (2 h / 4 h) and the new limits;
  - HPWL after `dpl` and `cts`;
  - `grt` total demand and Metal3, against 101.17 % / 115.27 %;
  - WNS at the latest stage.

  If `gpl` still reverts, or any gated stage fails, stop and report to the user before
  changing anything else.

  — **Run `37108127061` (2026-10-03, `dff4df0`: D1 + D3, taped-out die, `stop_after=grt`): `grt ok`.**
  Every gated stage passed (`floorplan`, `pre_place`, `gpl`, `dpl`, `cts`, `grt`); the `pnr` job
  finished at 22:41Z, 14 h 37 m after P&R started. Placement report: "gpl pass 2 converged without a
  revert". Both passes end with `GPL-1001` (pass 2 at iteration 1,682), and both timing-driven
  iterations are `virtual: true`.

  | | 34938462965 (09-15, ok) | 37108127061 (D1) |
  |---|---:|---:|
  | gpl pass 2 | reverted, overflow 0.189 | converged |
  | final placement area (`GPL-1014`) | +29.5 % | +45.3 % |
  | `DPL-0009` utilization | 62.9 % | 60.8 % |
  | illegal cells, legalizer iteration 0 | 82,811 | 106,255 |
  | HPWL after `dpl` | 148.8 M µm | 81.0 M µm (−46 %) |
  | HPWL after `cts` legalization | 166.3 M µm | 124.7 M µm (−25 %) |
  | `grt` total demand | 101.17 % | 83.57 % |
  | `grt` Metal3 | 115.27 % | 108.99 % |
  | `grt` wirelength | 204.2 M µm | 169.9 M µm (−17 %) |
  | WNS / TNS at `dpl` | −0.63 ns / −1.75 | −0.87 ns / −305.73 |
  | WNS / TNS at `cts` | −8.22 ns / −21,823 | −3.18 ns / −19,363 |
  | WNS / TNS at `grt` | −14.76 ns / −55,441 | −8.36 ns / −44,095 |
  | power at `grt` (`report_power`, default activity, typ) | 1.46 W | 1.82 W |

  Per-stage runtimes (from the job log): `floorplan` 4 m, `pre_place` 7 m, `gpl` 2 h 37 m, `dpl`
  1 h 40 m (would have fit the old 2 h), **`cts` 6 h 58 m (over the old 4 h limit: D3's 8 h was
  needed)**, `grt` 3 h 10 m. The `upload-checkpoints` job then waited behind the nightly synth lane
  for the single self-hosted runner, until the user cancelled that run (2026-10-04). The illegal-cell count is still
  above the good run's, from a converged but larger-area placement. Power is higher, with the cause
  not investigated; it is default-activity SoC power, not a workload figure.

- [x] 6.2 **[long-run]** If 6.1 fails or stalls, dispatch with die scale 1.10. — not needed: 6.1
  reached `grt`. The default went back to `1.0` (the user's call, 2026-10-04); `die_scale=1.10`
  stays available as an input for a larger netlist.

## 7. Merge and the clean reference

- [x] 7.1 **[edit]** After 6.1 reaches `grt`: tick the Phase 11 action, and record that P&R
  figures from before this change are not comparable with figures from after it. — done
  (`docs/infra-plan.md` Phase 11: action ticked, run 37108127061's figures and the
  non-comparability note).
- [x] 7.2 **[long-run]** After merge, ask the user, then dispatch `pnr.yml` on `main` (full
  flow). Verify `grt ok`. Record the stage reached, WNS and power, and `grt` congestion, as the
  reference for `sha3-cvxif-coprocessor` task 5.4. — **not dispatched: the user's call
  (2026-10-04) is that run `37108127061` counts as the reference.** It used the same netlist and
  the same settings `main` has after this merge (taped-out die, `pnr_gpl_keep_resize 0`, 0.65,
  `dpl` 4 h / `cts` 8 h). Reference: `grt ok`, WNS −8.36 ns, TNS −44,095 ns, default-activity
  power 1.82 W (typ), `grt` demand 83.57 %, Metal3 108.99 % (6.1 table).
