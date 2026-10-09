# Design

## Context

`report_metrics` in `target/ihp13/openroad/scripts/reports.tcl` ends every stage's report with `report_power -corner tt` and `report_power_metric -corner tt`. It sets no activity, so OpenSTA propagates its default:

- Primary inputs get density `0.1 / fastest clock period` and duty 0.5.
- Activity crosses flip-flops in at most 50 passes. This limit is the compile-time constant `max_activity_passes_`.
- Flip-flops the propagation never reaches stay at zero.

`report_metrics` is called by every staged script under `scripts/pnr/` and by `chip.tcl`. In `grt_repair.tcl`, a `repair_timing -recover_power` follows a `report_metrics` call inside the same OpenROAD process.

Measurements from 2026-10-09 (OpenROAD `26Q3-1740-g2c56926971`, the `newt-eda:dev` image, the flow's own `init_tech.tcl` and SDC, synth-lane `basilisk-netlist` artifacts). Both-arms default power reproduces CI's `pre_place` 0.610 W exactly.

| netlist (synth run) | default activity | passes / last max change | `-global -activity 0.1 -duty 0.5` |
| --- | ---: | --- | ---: |
| reference (`36447894410`) | 0.997 W | 50 (cap) / ~1,900× | 1.750 W |
| `keccak_cvxif` only (`37005575294`) | 9.18 W | 50 (cap) / ~70,000× | 1.856 W (+6.1 %) |
| both arms (`37218328058`) | 0.610 W | 50 (cap) / 2× | 2.006 W (+14.6 %) |

Default activity per module (mW, total / switching):

- `i_keccak_cvxif`: 8,100 / 3,692 with the coprocessor only, 14.5 / 0.00 with both arms.
- CVA6: 446 / 84.5 (reference), 518 / 136 (coprocessor only), 154 / 0.19 (both arms).
- Blocks driven straight from input pins (SPI, I2C, UART) are identical in all three.

Changing the reference's default input activity from 0.05 to 0.2 moves its total only from 0.987 to 1.014 W. The swings come from the netlist's structure, not from the input setting.

## Goals / Non-Goals

**Goals:**

- Every lane power figure is stable and comparable across netlists, and labelled for what it is.
- The diagnosis can be reproduced from the repository and an artifact, on a laptop.

**Non-Goals:**

- A realistic SoC power figure. Uniform activity is a comparison tool, not a power estimate.
- Changing timing, placement or routing in any way.

## Decisions

### D1. Uniform activity via `set_power_activity -global`, scoped to the report

Before `report_power`, `report_metrics` sets `set_power_activity -global -activity 0.1 -duty 0.5`. After `report_power_metric`, it calls `unset_power_activity -global`. It also writes one line into the report naming the setting and stating that the figure is comparative.

- **Why global:** it skips propagation entirely. OpenSTA does not propagate when a global activity is set, so the result cannot depend on convergence. It also gives the monotonic comparison measured above. Clock pins keep their clock-derived activity either way.
- **Why scoped:** `grt_repair.tcl` runs `repair_timing -recover_power` after a `report_metrics` in the same process. Unsetting keeps the spec's "does not leak" scenario. The probe already confirmed that `unset_power_activity -global` restores default propagation, because the reference's post-unset runs matched its default figure.
- **Why `-activity 0.1`:** it is the value measured above, so the docs' numbers come from the setting the lane uses. Note that OpenSTA divides `-activity` by the fastest defined clock's period, and that `-clock` is parsed but ignored in this version. The figure is therefore tied to the SDC's clock set, which is the same for every netlist. The report line names the fastest clock's period.
- **Alternatives rejected:**
  - Keep default activity and only add a label. The number still swings by 15×, and a label doesn't make it usable.
  - Remove `report_power` from the lane. That loses a cheap, stable comparison, and a removed section looks like a regression in old-vs-new report diffs.
  - `-input` with a different value. This was measured to make almost no difference.
  - Raise OpenSTA's pass cap. It is a compile-time constant, needs an OpenROAD rebuild, and does not fix the structural ill-conditioning.

### D2. A reproducible probe on synthesized netlists

New `target/ihp13/openroad/scripts/soc_power_probe.tcl`:

- Sources `init_tech.tcl` (with `pdk_dir` set as the flow does), reads `NETLIST`, links `iguana_chip` and reads `src/basilisk.sdc`.
- Reports default-activity power with `power_activity` debug on (one line per propagation pass), then uniform-activity power.
- Writes a per-instance power dump.

New `scripts/soc_power_agg.py` sums the dump by top-level module path. OpenROAD links flat, so hierarchical-instance queries return nothing and grouping has to be done on instance names. A Make target (`soc-power-probe NETLIST=...`, in `target/ihp13/openroad/openroad.mk`, named like its `run-pnr` neighbours) runs both. Output goes to `target/ihp13/openroad/out/power-probe/`, which is already git-ignored (`target/ihp13/*/out/`).

- **Why on the synthesized netlist:** the gap is already there at `pre_place`, `report_power` needs no placement, and the netlists are synth-lane artifacts. No VM and no 2.5 h synthesis are needed. It takes about 25 min per netlist under amd64 emulation on an M3 Max.
- **Why commit it:** the thesis requires results to be reproducible from the repository. The scratchpad version used for the diagnosis would otherwise be lost.

### D3. Docs carry the measured diagnosis

- `docs/infra-plan.md` Phase 17 is rewritten around the measurements above and marked done. The "diagnose in the lane" and "isolate" items are closed by the probe. "Fix or document" is closed by D1. The "re-measure" item is closed by the probe's uniform-activity comparison, with no P&R re-run.
- The SoC-power paragraph in `scripts/sha3_ppa.py` is edited in the generator, not in the generated `docs/results/sha3-ppa.md`, and `sha3-ppa.md` is regenerated. The paragraph keeps "SoC power: not reported" and replaces its reason.
- `docs/results/sha3-evaluation.md` is hand-written and is edited directly.

## Risks / Trade-offs

- [Uniform activity overstates sequential power (1.59 W vs 0.65 W on the reference), because every flip-flop toggles 0.1 per cycle] → It is labelled comparative. No absolute figure is quoted from it.
- [P&R power figures from before and after this change differ in kind] → The proposal marks this BREAKING for comparisons. Phase 17 records the cut-over commit. No earlier lane power figure is used by the thesis.
- [Regenerating `sha3-ppa.md` needs the run directories `sha3_ppa.py` was given] → If they are not available locally, edit the generator and apply the identical text change to the generated file by hand. Note this in the commit.
- [The probe's `get_cells *` dump is about 100 MB per netlist] → It is written to a scratch or output directory that is git-ignored, never into the repo.

## Migration Plan

The change takes effect on the next P&R lane run. No checkpoint or cache is invalidated: `reports.tcl` is not a synth cache-key input, and P&R checkpoints don't store activity. Rollback is reverting the `reports.tcl` hunk.
