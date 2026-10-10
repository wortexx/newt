# Proposal

## Why

Detailed routing has never run on a legal placement since the OpenROAD bump (`2c56926`). The bump made OpenROAD's new negotiation legalizer the default for `detailed_placement`, and on this design it never converges. It stops with `DPL-0701` and 15–24 k violations left, in `dpl` and in both of `cts`'s legalization passes. It then hands on whatever it has. `cts.tcl` catches the failed `check_placement` (`DPL-0033`) and reports it as a warning. Global routing doesn't mind overlapping cells, so every run so far reached `grt ok`:

| run | after `dpl` | after `cts` | `check_placement` after `cts` |
|---|---|---|---|
| reference `37108127061` | 16,661 left | 23,848 left | 12,596 overlaps, 53 on blocked layers |
| both arms `37162759719` | 15,539 left | 19,274 left | 9,718 overlaps, 63 on blocked layers |

Run `37996272102` (both arms, `main` at `b21a9b2`) was the first run since the bump to go past `grt`. `drt` aborted after 18 minutes, before routing iteration 0, with `DRT-0218 Guide is not connected to design` on two nets. The guides themselves are connected, so a pin lies outside its net's guides. That is what illegally placed cells produce.

The same OpenROAD build still ships the classic legalizer behind `detailed_placement -use_diamond_legalizer`. The 2024 tapeout flow used it. It either legalizes every cell or fails the call, so it never hands on a half-legal placement.

## What Changes

- **Legalizer selection.** Every `detailed_placement` call in the staged flow (`dpl.tcl`, `cts.tcl`, `grt_repair.tcl`) uses the legalizer named by a new setting, `pnr_dpl_legalizer`.
  - Values: `diamond` (`-use_diamond_legalizer`) and `negotiation` (OpenROAD's default).
  - The default becomes `diamond`.
  - `PNR_DPL_LEGALIZER` overrides it, and the P&R lane exposes it as the `dpl_legalizer` dispatch input.
  - **BREAKING** for comparisons: P&R figures from before this change come from illegal placements. They are not comparable with figures from after it.
- **Placement legality is gated.** `check_placement` runs after `dpl` and again at the end of `cts`. A failure fails that stage, so it can no longer pass as a warning. Both stages are already gated, so a run that cannot legalize now exits non-zero at the stage that failed, not at `drt` many hours later.
- **The placement report names the legalizer.** `run_pnr.sh`'s end-of-placement report states which legalizer ran and the `check_placement` outcome. It still states the illegal-cell count when the legalizer logs one.
- **Docs record the finding.**
  - `docs/infra-plan.md` Phase 11 gets the diagnosis, the table above and the outcome of the validation run.
  - `docs/results/sha3-evaluation.md` states that its P&R figures, on both sides, come from placements with 1.0–1.5 % of cells overlapping.

Flow stages touched: **backend** (OpenROAD stage scripts, `run_pnr.sh`), **CI** (one dispatch input in `pnr.yml`), **docs**. No RTL, synthesis, simulation or software change.

## Non-goals

- **Re-measuring the thesis P&R figures.** Re-running reference and both-arms P&R on legal placements, and requoting `sha3-ppa.md`, is a follow-up decision once this change shows legal placement works.
- **Making detailed routing converge.** This change removes the `DRT-0218` abort. Whether routing then converges on Metal3 at about 95 % demand is what the validation run measures, not something this change promises.
- **Enlarging the die.** `die_scale` already exists. It is the fallback if the diamond legalizer cannot fit the design on the taped-out die, and choosing it is a separate decision.
- **Legacy `chip.tcl`.** The single-process script is not used by the lane and is left as it is.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pnr-flow`: two changes.
  - New requirement: placement must be legal before routing, which makes the existing "a gated stage fails" behaviour cover illegal placement.
  - Modified requirement: "The run reports how global placement ended" now also names the legalizer and the `check_placement` result. Its illegal-cell count becomes conditional on the legalizer logging one.
- `ci-pipeline`: the P&R lane gains a `dpl_legalizer` dispatch input. Scheduled and tag runs use the default.

## Impact

- **Code:**
  - `target/ihp13/openroad/scripts/pnr/{common,dpl,cts,grt_repair}.tcl`
  - `target/ihp13/openroad/run_pnr.sh`
  - `.github/workflows/pnr.yml`
- **Docs:** `docs/infra-plan.md`, `docs/results/sha3-evaluation.md`, `docs/pnr-pipeline.md` (stage table: `dpl`/`cts` now check legality).
- **Runtime:** the diamond legalizer's runtime on about 977 k cells is unknown. The negotiation legalizer took 1.5–2.7 h per call, so stage timeouts may need revisiting from the validation run.
- **Risk:** the diamond legalizer may fail outright (no legal site within its search window) at 68–71 % utilization. The lane then goes red at `dpl` or `cts` instead of passing `grt`. That outcome is correct, but it ends the lane's green streak until the `die_scale` decision is made.
