# Tasks

Tags:

- **[edit]** plain editing, checked with cheap local validation: `openspec validate`, short OpenROAD calls in the `newt-eda:dev` image.
- **[eda]** loads a checkpoint in the image locally. CTS on the full design takes tens of minutes under emulation; the first run in 2.1 measures it.
- **[long-run]** a P&R lane dispatch on the VM, about 12 h. Always ask the user first.

Local checkpoints: `basilisk.dpl` and `basilisk.cts` of runs `44382400639` and `44708127322`, fetched from the `pnr-checkpoints` container the way `pnr.yml`'s "Download checkpoints from Blob" step does.

## 1. Tree-shape report (design D1)

- [x] 1.1 **[edit]** Add `pnr_report_clock_trees` to `scripts/pnr/common.tcl` per D1: depth, buffers, fanout ≤ 2, deepest-level sink span. It logs one line per tree and appends one `cts-tree` line per tree to `pnr_status.log`. Call it in `cts.tcl` right after `clock_tree_synthesis`, outside any error path, so it cannot change the stage's exit status. Verify with `git diff` that nothing else in `cts.tcl` changes.
- [x] 1.2 **[eda]** Verify on both runs' `cts` checkpoints. The proc runs on a checkpoint as is, after legalization and repair, so the spans differ slightly from the post-CTS values. It must report for `clk_i_regs`:
  - depth 11 and 14,380 buffers for `44382400639`;
  - depth 13 and 20,527 buffers, with about 8,192 more at fanout ≤ 2 than `44382400639`, for `44708127322`;
  - a span in µm for each;
  - one line per clock tree, matching the trees in each run's `pnr_cts.log` (`CTS-0018`).

  Record the numbers here.

  Done 2026-11-21, 14–16 s per checkpoint under emulation. Twelve trees each, with root, H-tree and leaf buffers matching the `CTS-0018` counts.

  | `clk_i_regs` | `44382400639` | `44708127322` |
  | --- | ---: | ---: |
  | depth | 11 | 13 |
  | buffers | 14,380 | 20,527 |
  | fanout ≤ 2 | 181 | 8,249 |
  | span | 3,661 µm | 3,550 µm |

  - The baseline's fanout ≤ 2 count is 181, not 0 as first expected: some leaf buffers drive only one or two flops. The difference, 8,068, is the extra levels' near-empty buffers.
  - The span is not the stop rule's number. `44382400639` stopped with every branch under 3,162 µm at decision time, yet its built tree has a deepest-level buffer spanning 3,661 µm. CTS evidently reassigns sinks after the level test, and the checkpoint is after repair and legalization. Design D1 and the proc's comment now call the span an indicator, and D2's selection uses it only to compare candidates.
  - The other trees differ a little between the runs, as expected after a different placement (e.g. `jtag_tck_i_regs` span 164 against 2,838 µm). All keep the same depth.
- [x] 1.3 **[edit]** Document the `cts-tree` log and status lines in `docs/pnr-pipeline.md`'s `cts` row (stage 5). Verify that the doc names the same fields as the code.

## 2. Settings probe (design D2)

- [x] 2.1 **[eda]** Write the scratch probe (not in the repo): load a `dpl` checkpoint, repeat `cts.tcl`'s steps through `clock_tree_synthesis` with options from the command line, run `pnr_report_clock_trees`, `estimate_parasitics -placement` and `report_power`.

  Run it with the current options on both `dpl` checkpoints. It must reproduce depth 11 / 14,380 buffers and depth 13 / 20,527 buffers. Record the run time. If it does not reproduce, stop, record what differs, and ask the user how to continue (design: Risks).

  Done 2026-11-22. Both reproduce exactly. Power uses `reports.tcl`'s activity (0.1, duty 0.5, corner `tt`). The probe measures right after `clock_tree_synthesis`, before clock-net repair, legalization and setup repair, so its fanout ≤ 2 and span differ from task 1.2's checkpoint values. Candidates are compared at this same point.

  | `clk_i_regs`, current options | `44382400639` | `44708127322` |
  | --- | ---: | ---: |
  | depth | 11 | 13 |
  | buffers | 14,380 | 20,527 |
  | fanout ≤ 2 | 47 | 8,239 |
  | span | 5,175 µm | 5,659 µm |
  | clock power | 0.352 W | 0.611 W |

  Run time under emulation: loading 7–11 min and `clock_tree_synthesis` 10.5–11 min. The total was 99 min for the first run and 35 min for the second, most of it in parasitics and power.
- [x] 2.2 **[eda]** Run the candidates in D2's order on both checkpoints. Record a table here with these columns:
  - candidate;
  - depth on each checkpoint;
  - buffers on each;
  - fanout ≤ 2 on each;
  - span on each;
  - clock power on each.

  Stop at the first candidate group that gives passes, after finishing that group's values.

  Done 2026-11-22. All three groups ran, and no candidate passes. Values are for `clk_i_regs`, measured right after `clock_tree_synthesis` (A = `44382400639`, B = `44708127322`).

  | candidate | depth A / B | buffers A / B | fanout ≤ 2 A / B | span µm A / B | clock W A / B | pass |
  | --- | --- | --- | --- | --- | --- | --- |
  | current options | 11 / 13 | 14,380 / 20,527 | 47 / 8,239 | 5,175 / 5,659 | 0.352 / 0.611 | — |
  | `-clustering_unbalance_ratio 0.7` | 11 / — | 14,380 / — | 47 / — | 5,175 / — | — | no effect |
  | `-clustering_exponent 3` | 13 / 11 | 20,524 / 14,383 | 8,239 / 47 | 4,655 / 4,904 | 0.576 / 0.357 | no, depths differ |
  | `-clustering_exponent 5` | 13 / 13 | 19,981 / 20,370 | 7,290 / 7,998 | 5,089 / 5,211 | 0.547 / 0.557 | no: power above 0.352 W, fanout ≤ 2 gap 3.5 % |
  | `-sink_clustering_size 12` | 11 / 13 | identical to current | | | | no effect |
  | `-sink_clustering_size 16` | 11 / 13 | identical to current | | | | no effect |
  | `-sink_clustering_max_diameter 50` | 12 / 13 | 20,848 / 25,025 | 152 / 4,488 | 5,506 / 4,738 | 0.541 / 0.701 | no, depths differ |

  - **Three options have no effect in this flow.** With a maximum fanout set (8, from the sink buffer), `refineBranchingPointsWithClustering` fixes the split capacity at half the sinks and ignores `-clustering_unbalance_ratio`, and `TritonCTS` caps the sink cluster size at the maximum fanout (`limitSinkClusteringSizes`), so 12 and 16 fall back to 8. The 0.7 run on A matched the current tree exactly, so 0.8 and B were not run.
  - **Exponent 3 swaps the outcome.** A goes to 13 levels and B to 11. The depth follows how the k-means split falls near the stop test, not the placement.
  - **The rest all pay in clock power.** Every other setting that changes the tree gives at least 0.54 W on A, against 0.352 W now.
  - The runs took 30 min each with the Mac awake. Sleep on battery stretched two of them to 94 min and about 5 h.
- [x] 2.3 **[edit]** Pick the default by D2's rule, or record that no candidate passed. If none passed, stop and ask the user before narrowing the change (design: Risks, last item). Verify that the chosen row meets both scenarios of the requirement "The register clock tree's depth does not flip on small placement changes".

  Done 2026-11-22. No candidate passed, so I asked the user. They chose a rebuild over narrowing to the report: build with the default exponent, and if the register tree is deep, rebuild once from `dpl` with exponent 3 and keep the shallower tree. The proposal, the second requirement (now "The CTS stage keeps the shallower of two register clock trees"), D2, D3, Risks and Migration were rewritten to match.

  Checked against 2.2's table, at the probe's 10 % near-empty threshold:
  - A: build 1 is shallow (11 levels, 0.3 %), so it is kept. Clock power is unchanged at 0.352 W.
  - B: build 1 is deep (13 levels, 40 %), so it is rebuilt with exponent 3. Build 2 is shallow (11 levels, 14,383 buffers, 47 near-empty, 0.357 W) and is kept.
  - Same depth on both, and the near-empty counts are equal (47 / 47).

## 3. Rebuild in the flow (design D2, D3)

- [x] 3.1 **[edit]** In `common.tcl`, add the knobs `PNR_CTS_CLUSTERING_EXPONENT`, `PNR_CTS_REBUILD_EXPONENT` and `PNR_CTS_BUILD`, validated like the other `PNR_*` knobs. Add a proc that, from `pnr_report_clock_trees`' result, returns the register tree (most buffers) and whether it is deep (> 10 % fanout ≤ 2).

  In `cts.tcl`:
  - pick the build's exponent;
  - log the full `clock_tree_synthesis` command line;
  - after the report, apply D2's rule: write `cts_build1.txt`, the `cts-build` and `cts-kept` status lines, and exit 75 before any save when a rebuild is due.

  Verify with `git diff` that everything after the rule is unchanged.

  Done 2026-11-22. The `git diff` of `cts.tcl` touches only the `clock_tree_synthesis` call, the report and the rule; from `repair_clock_nets` on, nothing changed.
- [x] 3.2 **[edit]** In `run_pnr.sh`'s attempt loop, handle exit 75 from `cts` per D3: log `cts rebuild build=<n>`, export `PNR_CTS_BUILD`, rerun, cap at build 3, and do not use the retry budget. Document the knobs in the header's environment list. Verify with `bash -n` and `PNR_DRY_RUN=1`.

  Done 2026-11-22. `bash -n` passes, and the dry run plans the same ten stages as before. In the image, `openroad -exit` returns a script's `exit 75` as its exit status, and `-log` overwrites the log. So after a rebuild, `pnr_cts.log` holds only the kept build, and `sha3_ppa.py`'s `CTS-0018` sum stays correct. `sha3_ppa.py` keeps the last non-`ok` status per stage, so the `cts rebuild` line is overridden by `cts ok`. `PNR_CTS_BUILD` is unset after `cts`.
- [x] 3.3 **[eda]** Verify through the flow's own code, by running `cts.tcl` against each `dpl` checkpoint locally with the driver's handling reproduced by hand (or `run_pnr.sh` resumed at `cts` with `PNR_STOP_AFTER=cts`):
  - A keeps build 1 at depth 11;
  - B exits 75 on build 1, and build 2 keeps depth 11 with 14,383 buffers;
  - `PNR_CTS_REBUILD_EXPONENT=off` on B keeps build 1;
  - `PNR_CTS_CLUSTERING_EXPONENT=x` fails the stage with a message naming the variable.

  Each status line must match.

  Done 2026-11-22 with the real `run_pnr.sh` and `cts.tcl`, under a scratch wrapper. The wrapper stops the stage at `repair_clock_nets`, right after the decision, and placeholder files stand in for the checkpoints before `dpl`.

  | case | status lines |
  | --- | --- |
  | A, defaults | `cts-build 1 exponent=default … depth=11 buffers=14380 fanout_le2=47 deep=0`, `cts-kept build=1` |
  | B, defaults | `cts-build 1 … depth=13 buffers=20527 fanout_le2=8239 deep=1`, `cts rebuild build=2`, `cts-build 2 exponent=3 … depth=11 buffers=14383 fanout_le2=47 deep=0`, `cts-kept build=2` |
  | B, `PNR_CTS_REBUILD_EXPONENT=off` | `cts-build 1 … depth=13 … deep=1`, `cts-kept build=1` |
  | A, `PNR_CTS_CLUSTERING_EXPONENT=x` | `cts failed exit=1`; the log has `PNR_CTS_CLUSTERING_EXPONENT='x' is not an exponent: …` |

  - Both placements keep an 11-level tree with 47 near-empty buffers, which meets the requirement's two-placement scenario.
  - Each build took about 17–18 min under emulation.
  - The driver exits 1 in all cases only because `PNR_STOP_AFTER=cts` stops before the `grt` gate, which is existing behaviour.
  - The run showed that `utl::report` treats its message as a format string. The logged command line, whose `-buf_list` value contains braces, was dropped with `[logger] argument not found`. `cts.tcl` now maps the braces to quotes before logging, which a one-line test in the image confirms (`clock_tree_synthesis -buf_list "a b" -x`).
- [x] 3.4 **[edit]** Document the rule, the exit code, the knobs and the `cts-build`/`cts-kept`/`cts rebuild` lines in `docs/pnr-pipeline.md`'s `cts` row and knob list. Verify that the names match the code. Run `openspec validate stabilize-cts-tree-depth --strict`.
- [x] 3.5 **[edit]** Rebase on `main` and open the PR with groups 1–3 and the change artifacts. After the user merges, the measured run dispatches on `main`.

## 4. Measured run

- [x] 4.1 **[long-run]** *(ask the user first)* Dispatch the P&R lane on `main` with every input empty and no resume. Save `pnr-reports` under `target/ihp13/openroad/out/ci-<run>/`. Verify:
  - the `cts-build`/`cts-kept` lines and the `cts-tree` line for `clk_i_regs`, with the kept tree below the 10 % threshold;
  - `drt ok` and `final ok`.
  - *Run `45035313880` (`e9affef`, 2026-11-22/23): build 1 deep (13 levels, 20,527 buffers, 8,239 near-empty), `cts rebuild build=2`, build 2 kept (11 levels, 14,383 buffers, 47 near-empty, 0.3 %); `drt ok`, `final ok`.*
- [x] 4.2 **[edit]** Compare with `44382400639` and `44708127322`: tree shape; clock and total power; area; WNS/TNS at `grt`; router markers; antenna counts. Report a WNS loss of more than 0.5 ns against `44382400639` to the user before keeping the rule. Add a `docs/infra-plan.md` record with the cause, the probe table, the rule and this run. Verify that the record's numbers match the reports.
  - *Same placement as `44708127322` (byte-identical `dpl` report). At `grt` against it: clock power 0.668 → 0.372 W, area 18.85 → 18.32 mm², WNS −13.20 → −12.89 ns, TNS level, router markers 120 → 22. WNS is 0.84 ns worse than `44382400639`'s (placement A); reported to the user, who kept the rule on 2026-11-23. Record in `docs/infra-plan.md` Phase 11.*

## Workflow follow-up

- Archive the change after the measured run is recorded and the user has merged the record.
- `snap-delay-lines-and-fill-tm1-gaps` task 3.3 cites this change for the PPA difference of run `44708127322`.
