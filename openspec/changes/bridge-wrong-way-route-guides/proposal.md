# Proposal

## Why

Detailed routing has never run on this SoC since the OpenROAD bump (`2c56926`). Every attempt aborts during guide processing with `DRT-0218 Guide is not connected to design`, before routing iteration 0. That includes run `38094932339`, which placed legally at `die_scale=1.10`.

Probes on branch `drt-0218-probe` traced the cause to global routing. It can emit a guide that spans several gcells against its layer's preferred direction, for example a guide running vertically on Metal2, a horizontal layer. Detailed routing's guide graph moves along a layer only in its preferred direction. A pin whose only link to the rest of its net runs through such a guide is therefore an island, and detailed routing's own guide patching does not reconnect it.

| run (resumed from `38094932339`'s `grt` checkpoint) | change before `detailed_route` | guide processing |
|---|---|---|
| `38094932339` | none | `DRT-0218` on `clknet_12_3602__leaf…` |
| `38138040839` | disconnect `clkbuf_leaf_7247/A` and `clkbuf_leaf_7191/A` | passed |
| `38163283136` | disconnect `clkbuf_leaf_7191/A` only | `DRT-0218` |
| `38165507881` | disconnect `clkbuf_leaf_7247/A` only | passed |
| `38169388017` | copy each wrong-direction guide onto the adjacent preferred-direction layer (1,264 guides on 639 nets) | passed |

Two more pieces of evidence:
- **A model of the rule matches.** Preferred-direction moves plus vias, with Metal1 excluded, reproduce all four pin-level outcomes. Allowing moves in any direction gets two of them wrong.
- **Every failure fits the pattern.** All three nets that ever failed `DRT-0218` have guides that are connected in any direction but split under the preferred-direction rule: one in run `38094932339`, two in run `37996272102`.
- **It reproduces locally.** The same OpenROAD build fails from the `grt` checkpoint alone, using nothing but `read_db`, `set_routing_layers` and `detailed_route`.

## What Changes

- **Bridge wrong-direction guides before detailed routing.**
  - **Where:** `drt.tcl`, after the routing layers are applied.
  - **What:** every guide on a routing layer (Metal2 to TopMetal1) that spans more than one gcell against its layer's preferred direction is copied onto the adjacent routing layer whose preferred direction matches: the layer above, or below for TopMetal1.
  - **What stays:** global routing's own guides are kept, and nothing is removed.
  - **Logging:** the stage logs how many guides it added on how many nets.
- **Setting.** `pnr_bridge_guides` (`PNR_BRIDGE_GUIDES`) defaults to on, and `0` turns the bridge off. There is no dispatch input: `pnr.yml` has no room for one that this decision needs.
- **`drt` budget.** A routing iteration takes about 3 h on the enlarged die, and the violation count barely falls after the first two (3.12 M → 2.64 M → 2.58 M, run `38178131540`). The lane's 8 iterations would hit any reasonable timeout, and a timeout loses the stage's output. So `PNR_DRT_END_ITER` drops to 5 (about 15.5 h), and `PNR_TIMEOUT_DRT` rises to 24 h as margin. The job's 48 h ceiling still holds for a full scheduled run (about 6 h to `grt`).
- **Docs:** `docs/infra-plan.md` Phase 11 and `docs/pnr-pipeline.md` (the `drt` stage and its timeout).

Flow stages touched: **backend** (`drt.tcl`, `common.tcl`) and **CI** (one timeout in `pnr.yml`), plus **docs**. No RTL, synthesis, simulation or software change.

## Non-goals

- **Fixing OpenROAD.** The bridge works around global routing's output. Reporting it upstream is optional follow-up.
- **Making detailed routing converge.** It does not at this congestion (about 2.6 M violations after three iterations). That needs the congestion levers in Phase 11, not this change.
- **GDS.** Streaming the DEF to GDS (`target/ihp13/klayout/`, KLayout not in the image) is a separate change.
- **Antenna repair and post-route timing repair** stay skipped, as today.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pnr-flow`: a new requirement that detailed routing must be able to traverse every net's route guides, so guide processing does not fail on a guide that only runs against its layer's preferred direction.

## Impact

- **Code:** `target/ihp13/openroad/scripts/pnr/{common,drt}.tcl`, `target/ihp13/openroad/run_pnr.sh` (header), `.github/workflows/pnr.yml` (`PNR_TIMEOUT_DRT`).
- **Cost:** a scheduled run now finishes `drt` in about 15.5 h instead of being cut off at 16 h with nothing saved; about the same VM time.
- **Routing:** the added guides only widen where detailed routing may go, on nets that already had a wrong-direction guide (about 0.07 % of nets in run `38094932339`).
- **Depends on** `use-diamond-legalizer` (PR #68) for a legal placement. This branch is based on it.
