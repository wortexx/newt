# Proposal

## Why

The P&R lane's `report_power` uses OpenSTA's default activity, and on this SoC that number is meaningless. Phase 17 of `docs/infra-plan.md` saw the both-arms netlist report about half the reference's power. Investigation on 2026-10-09 found the cause in OpenSTA, not the design:

- Default-activity propagation **never converges** on any of the three netlists. It stops at its 50-pass cap while activities are still changing by 2× to 70,000×.
- Three nearly identical netlists then report **0.997 W** (reference), **9.18 W** (coprocessor only, with 8.1 W inside the Keccak block) and **0.610 W** (both arms, with zero switching in CVA6 and both Keccak blocks).

The lane prints these numbers at every stage, next to real figures. Comparing any two of them is noise. The thesis does not quote them, but the results docs still describe the cause as "not investigated".

## What Changes

- **Lane power reports use a stated, uniform activity.** `report_metrics` sets one switching activity on every net before `report_power` / `report_power_metric`, and clears it afterwards. The report is labelled as uniform-activity and comparative only, not workload power. **BREAKING** for comparisons: P&R power figures from before this change are not comparable with figures from after it.
- **A reproducible SoC power probe.** A small OpenROAD script reads a synthesized netlist with the flow's own `init_tech.tcl` and SDC. It reports default-activity power and its propagation passes, uniform-activity power, and per-instance power. A module-level aggregator goes with it. The script needs only a `basilisk-netlist` artifact, not the VM or a new synthesis.
- **Docs record the finding.**
  - `docs/infra-plan.md` Phase 17 gets the diagnosis, the measurements and the closed items.
  - The SoC-power note in `scripts/sha3_ppa.py` (it generates `docs/results/sha3-ppa.md`) and the hand-written note in `docs/results/sha3-evaluation.md` no longer say "stops propagating, not investigated". They say: non-converged default activity, comparison only under uniform activity, no SoC power quoted.

Flow stages touched: **backend** (OpenROAD report script), **CI** (only the lane's report content changes; no workflow edit), **docs**. No RTL, synthesis or simulation change.

## Non-goals

- Workload-annotated SoC power (a SoC-level SAIF from a full-SoC simulation). This is out of reach here and not needed by the thesis.
- Making OpenSTA's default propagation converge, for example by raising its pass cap. That cap is a compile-time constant in OpenSTA, and the propagation is ill-conditioned anyway.
- Re-dispatching P&R runs only to re-measure power. The probe on synthesized netlists already gives the comparison.
- The unexplained `cva6` area shrink when CV-X-IF is on. It is a separate open question.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pnr-flow`: "Flow emits end-of-run reports" gains a requirement on power reports. They SHALL state their activity assumption, and SHALL NOT report OpenSTA's unconverged default activity as the design's power.

`sha3-evaluation` is unchanged. Its rule against default activity for block power already holds, and the "unavailable stage is reported with its reason" scenario covers SoC power. Only the stated reason changes.

## Impact

- `target/ihp13/openroad/scripts/reports.tcl` (`report_metrics`): its power section. Used by every staged P&R script and by `chip.tcl`.
- New: `target/ihp13/openroad/scripts/soc_power_probe.tcl` and `scripts/soc_power_agg.py`, plus a Make target to run them.
- `scripts/sha3_ppa.py` and the regenerated `docs/results/sha3-ppa.md`; `docs/results/sha3-evaluation.md`; `docs/infra-plan.md`.
- No change to block-level power (`target/ihp13/yosys/scripts/block_power.tcl`), which is SAIF-annotated and unaffected.
