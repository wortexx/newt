# Design

## Context

`drt.tcl` loads the `grt_repaired` checkpoint, re-applies dont-touch, dont-use and routing layers (`pnr_apply_routing_layers`: signal and clock on Metal2 to TopMetal1), optionally runs antenna repair (skipped in the lane), then calls `detailed_route`. Global routing's guides travel inside the `.odb` checkpoint as `dbGuide` objects. Detailed routing reads them from there (`DRT-0156 guideIn read …`).

Facts established on branch `drt-0218-probe` (see proposal.md):

- **Layer directions** (`sg13g2_tech.lef`): Metal1 vertical, Metal2 horizontal, Metal3 vertical, Metal4 horizontal, Metal5 vertical, TopMetal1 horizontal, TopMetal2 vertical.
- **Gcell grid:** 6.3 µm (6300 dbu), from the block's `dbGCellGrid`.
- **Global routing's own guides** carry their own layer as via layer for plain segments, or the next layer up where a via is meant.
- **Tcl access** in this build: `odb::dbGuide_create net layer via_layer rect is_congested` and `odb::new_Rect` create guides. `dbTechLayer getDirection` returns `HORIZONTAL` or `VERTICAL`.
- **Measured on the probe:** walking about 13 M guides in Tcl and adding 1,264 of them took well under a minute on the VM.

Detailed routing's guide graph (`GuidePathFinder`, `src/drt/src/io/GuideProcessor.cpp` at `2c56926`) is a black box here. The rule "moves along a layer only in its preferred direction" is inferred from the probes, not read from the code.

## Goals / Non-Goals

**Goals:**
- `drt` gets past guide processing on this design, in the scheduled lane, with no per-run input.
- A minimal, auditable change to what detailed routing sees: guides are only added, and the stage log says how many.

**Non-Goals:**
- Changing global routing's parameters to stop producing wrong-direction guides. It is unclear which parameter would, and global routing takes about 2 h per try.
- Removing the probe hooks. They live only on branch `drt-0218-probe`, which is not merged.

## Decisions

### D1. Add a copy on the adjacent preferred-direction layer; never remove

For a guide on routing level L (Metal2 = 2 … TopMetal1 = 6) that spans more than one gcell against L's direction, add the same rectangle on level L+1, or L−1 for TopMetal1. The via layer is the new layer itself, as for global routing's plain segments. Adjacent levels alternate direction, so L±1 always runs the right way.

This is exactly what probe 5 (run `38169388017`) did, and it passed.

*Alternative:* replace the wrong-direction guide. Rejected: removing a guide could disconnect a pin that relied on its pin-layer overlap. Adding cannot disconnect anything.

*Alternative:* bridge only around pins. Rejected: it adds a pin analysis that depends on detailed routing's access points, which are not in the checkpoint, and the plain rule already passed.

### D2. One helper in `common.tcl`, called from `drt.tcl`

`pnr_bridge_wrong_way_guides` holds the code. It collects first and creates afterwards, so the guide list is never mutated while being walked. It reports `Bridged <n> wrong-direction guides on <m> nets`. `drt.tcl` calls it after `pnr_apply_routing_layers`, unless `pnr_bridge_guides` is 0.

*Alternative:* a separate stage between `grt_repair` and `drt`, with its own checkpoint. Rejected: about 250 MB of checkpoint per run for a step that takes under a minute. It runs once per `drt` process either way, so resuming at `drt` re-applies it.

### D3. Setting without a dispatch input

`pnr_bridge_guides` is read from `PNR_BRIDGE_GUIDES`: empty means 1, `0` turns the bridge off, and any other value is a Tcl error. It is documented in `run_pnr.sh`'s header. `pnr.yml` gets no input for it, because `main` has 9 of GitHub's 10 and turning the bridge off is a diagnostic, not a lane mode.

### D4. `drt` timeout 24 h

The stage's 16 h timeout (`run_pnr.sh` default) would cut 8 iterations of about 2.5 h each, and a timeout leaves no checkpoint and no DEF. `pnr.yml` sets `PNR_TIMEOUT_DRT=86400`. The job ceiling stays 48 h (`timeout-minutes: 2880`), and a full scheduled run reaches `drt` in about 6 h.

*Alternative:* fewer iterations (`PNR_DRT_END_ITER=5`). Kept as the lever if the validation run shows later iterations do not get faster. The iteration count is the primary bound by the spec's own wording, and the timeout is the backstop.

## Risks / Trade-offs

- **[The inferred rule is incomplete: another net fails for a different reason]** → The validation run shows it: `DRT-0218` names the net. The probe branch's dump mode can be revived for it.
- **[Added guides change routing on about 640 nets]** → They only widen the search region, on nets that already had a wrong-direction guide. Per-run counts are logged.
- **[24 h of `drt` per weekly run]** → About $10 more per run at most. If convergence is hopeless (violations flat across iterations), lower `PNR_DRT_END_ITER` in a follow-up rather than paying for the full budget every week.
- **[Upstream fixes global routing later]** → The step then adds zero guides and logs it. Nothing to undo.

## Migration Plan

1. Implement D1–D4 on branch `bridge-wrong-way-route-guides` (based on `use-diamond-legalizer`). Cheap checks: Tcl parse, a local run of the helper on the `grt` checkpoint, which must add exactly the probe's Metal3 guide on `clknet_12_3602…`, `shellcheck`, `actionlint`.
2. With the user's approval, dispatch the lane from the branch, resuming from run `38094932339` with no exclusions: the stages up to `grt_repaired` are restored and `drt` runs. Record guide processing, the violation count per iteration, `drt` runtime, whether `final` writes `basilisk.final.def`, and the DEF artifact.
3. Merge after #68.

Rollback: `PNR_BRIDGE_GUIDES=0`, or revert.
