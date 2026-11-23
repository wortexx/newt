# Proposal

## Why

Run `44708127322` (change `snap-delay-lines-and-fill-tm1-gaps`) moved the two delay lines 0.16 µm. That changed global placement, and clock tree synthesis then built the register clock tree two levels deeper than run `44382400639`'s. Nothing else about the trees differed:

| | `44382400639` | `44708127322` |
|---|---:|---:|
| `clk_i_regs` sinks / sink clusters | 92,824 / 11,613 | 92,824 / 11,616 |
| H-tree levels | 11 | **13** |
| tree buffers | 14,380 | **20,527** |
| buffers driving 1–2 sinks | 0 | **8,192** |
| clock power at `grt` | 0.373 W | **0.668 W** |
| total power / cell area at `grt` | 1.04 W / 18.27 mm² | 1.34 W / 18.85 mm² |
| WNS at `grt` | −12.05 ns | −13.20 ns |
| router markers after `drt` | 5 | 120 |

The cause is TritonCTS's rule for stopping the H-tree (OpenROAD `2c56926971`, `HTreeBuilder::run`). Once a level averages fewer sinks per sub-region than the buffer's maximum fanout (8 here), the tree stops only if no branch's sinks span more than the resizer's maximum wire length (3,162 µm). Otherwise it adds levels for as long as that span keeps shrinking.

In both runs, the sink clusters are split by capacitated k-means, and some branches get sinks about 2.4 mm apart (x ≈ 1,170 and 3,570 µm). So at level 11 the widest branch sits right at the limit. The baseline passed it narrowly; the new placement did not. Each extra level doubles the tree's leaves for the whole clock, which is where the 8,192 near-empty buffers come from.

The thesis compares PPA between design variants, and every variant moves placement. A clock tree that can add 0.3 W (29 %) and 3 % of area on a 0.16 µm move makes those comparisons noise. The flow needs to stop at a stable depth, and it needs to report the tree's shape so that a flip is visible in the status log instead of being found by hand.

## What Changes

- **Report the clock tree's shape.** After `clock_tree_synthesis`, the `cts` stage measures every clock tree it built: its H-tree depth, its buffer count, and how many buffers drive only one or two sinks. It logs these and writes them to `pnr_status.log`, so runs can be compared without re-parsing the CTS log.
- **Keep the shallower register tree.** A local probe on both runs' `dpl` checkpoints (2026-11-22) found no single CTS setting that stops the tree at the same depth on both without costing clock power. Three of the exposed settings have no effect here, because the buffer's maximum fanout overrides them. The others change the tree but add at least 0.19 W of clock power. One finding made a retry work, though: with `-clustering_exponent 3` instead of the default 4, the two placements swap depths (13 and 11). So the `cts` stage now:
  - builds the tree with the default settings and measures it;
  - if the register tree has the deep tree's signature, a large share of buffers driving only one or two sinks, rebuilds it once from the `dpl` checkpoint with `-clustering_exponent 3`;
  - keeps whichever of the two has fewer such buffers.

  The exponent and the retry each have an environment override, like the other stage knobs. The probe's table is the evidence, recorded in `tasks.md` and `docs/infra-plan.md`.
- **Measured run.** One VM dispatch from `floorplan` with lane defaults, compared with both runs. The result is recorded in `docs/infra-plan.md`.

Stages touched: **backend** only (`scripts/pnr/cts.tcl`, `scripts/pnr/common.tcl`, `run_pnr.sh`). Not touched: RTL, sim, synth, sw, CI workflow inputs.

Non-goals:

- Changing OpenROAD itself or its pinned version. A patch to the H-tree stop rule would be the direct fix, but it means a fork and an image rebuild.
- The monolithic `scripts/chip.tcl`. It runs CTS once in one process and cannot rebuild from a checkpoint, so it keeps today's call.
- Clock skew, latency or useful-skew tuning. Only the tree's depth and its cost are in scope.
- The router's marker count. It follows placement and is tracked by the existing `drt` reports.
- New `pnr.yml` dispatch inputs. The settings stay overridable through the environment only.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pnr-flow`: two added requirements. The CTS stage reports each clock tree's shape. The CTS stage keeps the shallower of two register clock trees.

## Impact

- `scripts/pnr/cts.tcl`: the tree-shape report after `clock_tree_synthesis`, the deep-tree test, and the exit that asks for a rebuild.
- `scripts/pnr/common.tcl`: the tree-shape report proc and the CTS environment knobs.
- `run_pnr.sh`: reruns `cts` from the `dpl` checkpoint when the stage asks for a rebuild. A rebuild is not a failure and does not use the stage's retry budget.
- `docs/pnr-pipeline.md`: the `cts` row names the new log and status lines and the knobs.
- Thesis figures: on `44708127322`'s placement the clock tree returns to 11 levels, so clock power, area and WNS move back towards `44382400639`'s. The measured run becomes the reference for later variant comparisons.
- Cost: a rebuild adds one checkpoint load and CTS run (under 30 min on the VM) to runs that hit the deep tree. Plus one VM run of about 12 h.
