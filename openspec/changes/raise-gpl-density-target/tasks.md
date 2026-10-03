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

## 6. Measure the revised plan

- [ ] 6.1 **[long-run]** Ask the user, then dispatch `pnr.yml` on this change's branch, full flow
  (no checkpoint matches; 3.1), `stop_after=grt`. Record in Phase 11, next to the 3.2 table:
  - pass 2 convergence (the placement report line);
  - illegal cells at iteration 0;
  - `dpl` and `cts` runtimes, against both the old (2 h / 4 h) and the new limits;
  - HPWL after `dpl` and `cts`;
  - `grt` total demand and Metal3, against 101.17 % / 115.27 %;
  - WNS at the latest stage.

  If `gpl` still reverts, or any gated stage fails, stop and report to the user before
  changing anything else.

## 7. Merge and the clean reference

- [ ] 7.1 **[edit]** After 6.1 reaches `grt`: tick the Phase 11 action, and record that P&R
  figures from before this change are not comparable with figures from after it.
- [ ] 7.2 **[long-run]** After merge, ask the user, then dispatch `pnr.yml` on `main` (full
  flow). Verify `grt ok`. Record the stage reached, WNS and power, and `grt` congestion, as the
  reference for `sha3-cvxif-coprocessor` task 5.4.
