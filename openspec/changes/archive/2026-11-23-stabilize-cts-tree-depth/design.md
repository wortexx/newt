# Design

## Context

See proposal.md (Why) for the two runs and their numbers.

- **The call.** `scripts/pnr/cts.tcl` and `scripts/chip.tcl` both call `clock_tree_synthesis -buf_list $ctsBuf -root_buf $ctsBufRoot -sink_clustering_enable -obstruction_aware`. `ctsBuf` is `sg13g2_buf_16/8/4/2` and the root buffer is `sg13g2_buf_8` (`init_tech.tcl`). Nothing else configures CTS.
- **Stop rule (OpenROAD `2c56926971`, `src/cts/src/HTreeBuilder.cpp`, `HTreeBuilder::run`).** Level L has `ceil(clusters / 2^L)` sinks per sub-region. When that drops below the maximum fanout (8, from the sink buffer), the tree stops if `LevelTopology::getLargestSinkRegionHPWL` is under the resizer's maximum wire length (`findMaxWireLength`, 3,162 µm; `RSZ-0058`). If not, it continues while that HPWL shrinks (`CTS-0054` stops it otherwise). The HPWL is the largest bounding box of the sink locations assigned to one branch.
- **Branch assignment.** `refineBranchingPointsWithClustering` splits each branch's sinks between its two children with capacitated k-means. The capacity is half the sinks whenever a maximum fanout is set, as here, and `sinks × -clustering_unbalance_ratio` (default 0.6) only otherwise. The distance weighting is `-clustering_exponent` (default 4).
- **What the checkpoints show.** In both runs' `cts` checkpoints, deep-level buffers drive sinks about 2.4 mm apart (x ≈ 1,170 and 3,570 µm), e.g. `clkbuf_11_1269` at 3,664 µm in `44382400639`, counting the buffer's own pin. So the level-11 test passes or fails on a few stray assignments near the limit.
- **Exposed settings.** No Tcl option sets the tree depth (`CtsOptions::clockTreeMaxDepth_` is internal) or the stop wire length. What is exposed: `-clustering_unbalance_ratio`, `-clustering_exponent`, `-sink_clustering_size`, `-sink_clustering_max_diameter`, `-sink_clustering_levels`, `-distance_between_buffers`, `-branching_point_buffers_distance`, `-balance_levels`, on `clock_tree_synthesis` and mostly also on `set_cts_config`.
- **Tree naming.** H-tree buffers are named `clkbuf_<level>_<index>_…<clock net>`, and the sink-cluster buffers `clkbuf_leaf_<index>_<clock net>`. Leaves are not H-tree levels.

## Goals / Non-Goals

**Goals:**

- A tree-shape report that makes a depth flip obvious, in every run.
- The same register tree depth on the two known placements, chosen by measurement and with the evidence recorded.

**Non-Goals:**

- Tuning skew or latency, or trading timing for clock power beyond holding the baseline.
- A fix inside OpenROAD (see D2's alternatives).
- The monolithic `scripts/chip.tcl`. It runs CTS once in one process, so it cannot rebuild from a checkpoint and keeps today's call.
- Explaining every stray k-means assignment. The probe needs only enough to choose settings.

## Decisions

### D1. Tree-shape report from the database, after `clock_tree_synthesis`

A proc in `common.tcl`, `pnr_report_clock_trees`, runs in `cts.tcl` right after `clock_tree_synthesis`, before `repair_clock_nets` or any legalization moves buffers. For each clock net it groups the `clkbuf_<n>_…` instances by the clock-net suffix and reports:

- **depth:** the largest `<n>`;
- **buffers:** the number of `clkbuf_*` instances of that tree, leaves included;
- **fanout ≤ 2:** buffers whose output net has one or two loads;
- **span:** for each deepest-level buffer, the bounding box (x extent plus y extent) of the instances it drives, excluding itself; the largest one, in µm. It shows branches whose sinks lie far apart. It is not the stop rule's own number, which comes from the sink assignment while the level is being decided: on `44382400639`'s `cts` checkpoint the span is 3,661 µm, yet that tree stopped under the 3,162 µm limit (task 1.2). So it is an indicator for comparing runs, not a margin to the limit.

It logs one line per tree and appends `cts-tree <net> depth=… buffers=… fanout_le2=… span_um=…` to `pnr_status.log`. It only reports and never fails the stage, so it cannot break an existing run.

- *Alternative: parse `CTS-0017`/`CTS-0018` from the log.* That was rejected. It gives only levels and buffers, not the span, and the lane already avoids re-parsing OpenROAD logs (`pnr_status` exists for that).
- *Alternative: gate on depth.* Rejected. No depth is right for every design variant, so a hard limit would fail runs for the wrong reason.

### D2. Rebuild once with another clustering exponent, keep the shallower tree

**The probe (tasks 2.1–2.2).** A scratch script loaded each run's `dpl` checkpoint, repeated `cts.tcl`'s steps through `clock_tree_synthesis` with candidate options, then ran D1's report and the power report. With today's options it reproduced both VM trees exactly (11 levels / 14,380 buffers, 13 / 20,527), so CTS is deterministic for a given checkpoint and options. No single setting passed:

- `-clustering_unbalance_ratio` and `-sink_clustering_size` have no effect here. With a maximum fanout set (8, from the sink buffer), `refineBranchingPointsWithClustering` fixes the split capacity at half the sinks, and `TritonCTS` caps the cluster size at the maximum fanout.
- `-clustering_exponent 5` and `-sink_clustering_max_diameter 50` change the tree, but both give at least 0.54 W of clock power on `44382400639` (0.352 W now), and the diameter setting still gives different depths.
- `-clustering_exponent 3` swaps the outcome: 13 levels on `44382400639` and 11 on `44708127322`.

So the depth is decided by how the k-means split falls near the stop test, not by the placement or a tunable margin. A setting cannot remove that, but a second, differently seeded build can avoid it: on these two placements, the default exponent or exponent 3 always gives the shallow tree.

**The rule.** `cts.tcl` builds with the first options, runs D1's report, and tests the register tree, the tree with the most buffers. It counts as deep when more than 10 % of its buffers drive one or two sinks. The probe's shallow trees have 0.3–0.7 % and its deep trees 18–40 %, so 10 % sits far from both. Then:

1. **Build 1, not deep:** continue the stage as today. One CTS run, the same tree as now.
2. **Build 1, deep:** write the tree's numbers to `${save_dir}/cts_build1.txt`, log a `cts-build` line, and exit with code 75 before anything is saved. The driver reruns the stage (D3), which loads `dpl` again and builds with exponent 3.
3. **Build 2, not deep, or with a smaller near-empty share than build 1:** keep it and continue.
4. **Build 2 worse than build 1:** exit 75 again. Build 3 repeats build 1's options, which is the same tree because CTS is deterministic, and keeps it without a test.

Each build appends `cts-build <n> exponent=<e> depth=… buffers=… fanout_le2=…` to `pnr_status.log`, and the kept one also `cts-kept build=<n>`.

- *Alternative: one fixed setting.* This was the original plan, and the probe ruled it out (table in `tasks.md` 2.2).
- *Alternative: patch the stop rule in OpenROAD,* for example to stop once each branch has fewer sinks than the fanout. That is the direct fix, but it needs a fork, an image rebuild and re-validating the flow. It stays a possible later change if a third placement defeats both builds.
- *Alternative: always run both builds and compare.* Rejected. It doubles CTS time on every run, and the rule above already keeps the better of the two when it matters.
- *Alternative: rebuild inside one OpenROAD process.* Not possible. OpenROAD has no way to remove a built tree or load a second database in the same process, so a rebuild needs a fresh process from the checkpoint.

### D3. The driver reruns `cts` on exit 75; knobs in `common.tcl`

In `run_pnr.sh`'s attempt loop, exit code 75 from `cts` means "rebuild requested". The driver logs `cts rebuild build=<n+1>`, exports `PNR_CTS_BUILD=<n+1>` and reruns the stage. This is not a failure: it does not use the retry budget, and it is capped at build 3, after which a 75 counts as a failure. Exit 75 is not used by any stage today, nor by `timeout` (124) or a crash.

`common.tcl` reads and validates the knobs like the other `PNR_*` variables:

- `PNR_CTS_CLUSTERING_EXPONENT`: build 1's exponent. Empty means OpenROAD's default (4). Setting it turns the rebuild off, so a run asking for a specific tree gets that tree.
- `PNR_CTS_REBUILD_EXPONENT`: build 2's exponent, default 3, or `off` to turn the rebuild off.
- `PNR_CTS_BUILD`: set only by the driver. Empty means 1.

An invalid value fails the stage with a message naming the variable. The stage log prints the full `clock_tree_synthesis` command line. No `pnr.yml` input is added. The stage timeout applies to each build.

## Risks / Trade-offs

- [A third placement makes both builds deep.] → The stage keeps the better build and completes, and the status file records both, so it shows at once. The fallback is then the OpenROAD patch named in D2.
- [The 10 % threshold misclassifies a future design variant.] → A shallow tree's near-empty share is set by how sinks cluster, which variants barely change. The threshold is a constant in `cts.tcl` with its evidence in the comment, so it is easy to revisit.
- [The rebuild costs time.] → Only runs that hit the deep tree pay for it: one more checkpoint load and CTS run, under 30 min on the VM.
- [The kept tree changes timing.] → The measured run compares WNS/TNS with both runs. A WNS loss of more than 0.5 ns against `44382400639` is reported to the user before the rule is kept.

## Migration Plan

Nothing to migrate. Resumed runs from `cts` onward keep their checkpoint's tree. A run from `floorplan` or `dpl` uses the rule. Rollback means setting `PNR_CTS_REBUILD_EXPONENT=off`, which restores today's single build.
