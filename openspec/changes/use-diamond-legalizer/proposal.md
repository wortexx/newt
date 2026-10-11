# Proposal

## Why

Detailed routing has never run on a legal placement since the OpenROAD bump (`2c56926`). The bump made OpenROAD's new negotiation legalizer the default for `detailed_placement`, and on this design it never converges. It stops with `DPL-0701` and 15–24 k violations left, in `dpl` and in both of `cts`'s legalization passes. It then hands on whatever it has. `cts.tcl` catches the failed `check_placement` (`DPL-0033`) and reports it as a warning. Global routing doesn't mind overlapping cells, so every run so far reached `grt ok`:

| run | after `dpl` | after `cts` | `check_placement` after `cts` |
|---|---|---|---|
| reference `37108127061` | 16,661 left | 23,848 left | 12,596 overlaps, 53 on blocked layers |
| both arms `37162759719` | 15,539 left | 19,274 left | 9,718 overlaps, 63 on blocked layers |

Run `37996272102` (both arms, `main` at `b21a9b2`) was the first run since the bump to go past `grt`. `drt` aborted after 18 minutes, before routing iteration 0, with `DRT-0218 Guide is not connected to design` on two nets. That is how the illegal placement above was found.

> **Correction (2026-10-12).** This proposal first named the illegal placement as the cause of `DRT-0218`. It is not. Run `38094932339` placed legally (both gated checks passed) and `drt` still aborted with `DRT-0218`. Probes on branch `drt-0218-probe` traced it to global routing: it can emit a guide that spans gcells against its layer's preferred direction, which detailed routing's guide graph cannot traverse. That fix is a separate change. This change stands on the illegal placement alone: the lane quoted P&R figures from overlapping cells, and the legalizer that produced them took hours to fail.

The same OpenROAD build still ships the classic legalizer behind `detailed_placement -use_diamond_legalizer`. The 2024 tapeout flow used it. It either legalizes every cell or fails the call, so it never hands on a half-legal placement.

## What Changes

- **Legalizer selection.** Every `detailed_placement` call in the staged flow (`dpl.tcl`, `cts.tcl`, `grt_repair.tcl`) uses the legalizer named by a new setting, `pnr_dpl_legalizer`.
  - Values: `diamond` (`-use_diamond_legalizer`) and `negotiation` (OpenROAD's default).
  - The default becomes `diamond`.
  - `PNR_DPL_LEGALIZER` overrides it, and the P&R lane exposes it as the `dpl_legalizer` dispatch input.
  - **BREAKING** for comparisons: P&R figures from before this change come from illegal placements. They are not comparable with figures from after it.
- **Legalizer search window.** A `pnr_dpl_max_displacement` setting (`PNR_DPL_MAX_DISPLACEMENT`, `dpl_max_displacement` dispatch input) passes `-max_displacement` to every legalization. Default `1000 1000` µm; `openroad` keeps OpenROAD's own window.
- **Default die.** `pnr_die_scale` defaults to `1.10` (6777 × 5950 µm), the user's call on 2026-10-12. On the taped-out die the SoC with both SHA-3 arms cannot be legalized after `cts`. **BREAKING** for comparisons: lane figures describe the enlarged die; `die_scale=1.0` reproduces the taped-out floorplan.
- **Placement legality is gated.** `check_placement` runs after `dpl` and again at the end of `cts`. A failure fails that stage, so it can no longer pass as a warning. Both stages are already gated, so a run that cannot legalize now exits non-zero at the stage that failed, not at `drt` many hours later.
- **The placement report names the legalizer.** `run_pnr.sh`'s end-of-placement report states which legalizer ran and the `check_placement` outcome. It still states the illegal-cell count when the legalizer logs one.
- **Docs record the finding.**
  - `docs/infra-plan.md` Phase 11 gets the diagnosis, the table above and the outcome of the validation run.
  - `docs/results/sha3-evaluation.md` states that its P&R figures, on both sides, come from placements with 1.0–1.5 % of cells overlapping.

Flow stages touched: **backend** (OpenROAD stage scripts, `run_pnr.sh`), **CI** (one dispatch input in `pnr.yml`), **docs**. No RTL, synthesis, simulation or software change.

## Non-goals

- **Re-measuring the thesis P&R figures.** Re-running reference and both-arms P&R on legal placements, and requoting `sha3-ppa.md`, is a follow-up decision once this change shows legal placement works.
- **Making detailed routing run.** `DRT-0218` turned out not to come from placement (see the correction above); its fix is a separate change.
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
