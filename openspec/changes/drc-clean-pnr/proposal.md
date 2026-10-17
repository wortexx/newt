# Proposal

## Why

Detailed routing does not converge on this SoC. On the current best layout (probe B, run `38473439796`), it ends 5 iterations with **715,558 violations**: 87 % shorts, spread over Metal2–Metal5. Iterations take 1.7–4.8 h each, so more iterations cannot finish inside the 24 h timeout.

The user's goal from 2026-10-16 is a **DRC-clean detailed route**: 0 violations, with antenna repair. Timing closure is out of scope. The thesis's current P&R figures are parked as a safety net (`requote-sha3-pnr-legal-placement`) and are re-run once a clean layout exists. Chip area is not a hard constraint, so a larger die is acceptable.

The violations show a capacity shortfall, not a few local defects:

- Global routing reports only 59.7 % demand and 74,776 overflowing edges, while detailed routing finds about 10× that, even with Metal2 and Metal3 already discounted 30 %.
- Placement packs cells to a local target density of 0.65, so the spare area of the enlarged die (56 % utilization) stays unused.

Spreading the placement is the first lever. Two of the flow's existing inputs, global-placement density and die scale, already control it, so the first experiments need no flow change.

## What Changes

- **P&R lane dispatch inputs.**
  - Add an input for detailed routing's iteration budget, today fixed at 5 in `pnr.yml`.
  - Add an input to run antenna repair, today always skipped.

  Empty keeps today's behaviour, so scheduled runs do not change.
- **Detailed-route reporting reports the router's own numbers.** That means the final violation count (`DRT-0199`), the count after each iteration, and the final table by type and layer. Today the status line reports `drc_report_lines`, which counts entries in the DRC report file. That file is capped at 10,000 entries per violation type, so the line says 21,110 where the router counted 715,558.
- **Probe sweep (Phase 1).** Three both-arms runs on `main`'s netlist that stop after detailed-routing iteration 1. Each varies the die scale and the placement density, and they are compared on violations after iterations 0 and 1.
- **Full route of the best probe (Phase 2).** Detailed routing to convergence, with antenna repair on.
- **Decision point (Phase 3).** If the best setting does not converge, choose among further levers with the user: cell padding, more signal capacity on TopMetal1/TopMetal2, or a lower `kperm` rounds-per-cycle. Each is scoped then, in this change or a follow-up.
- **First Phase 3 lever (added 2026-10-17, design D7).** P2 left Metal2 with 84 % of the violations. A `grt_metal2_adjust` input lets global routing hold back more of Metal2, so wires move up to Metal4/Metal5. It is tested from P2's checkpoints.
- **Out of scope.** Re-running the reference and both-arms thesis comparison on the new settings is a follow-up change. So are timing closure and signoff checks (KLayout DRC, LVS).

Flow stages touched: **backend** (detailed-route reporting) and **CI** (two new `pnr.yml` dispatch inputs). Several long P&R runs on the self-hosted VM, each dispatched only with the user's approval. No RTL, sim, synth or sw change. The default flow settings change only if a probe proves a better default, and then only by the user's decision.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `ci-pipeline`: "P&R lane runs weekly, on demand, and on tags — never per-PR" gains two dispatch inputs, the detailed-routing iteration budget and running antenna repair, both empty by default with today's behaviour kept.
- `pnr-flow`: a new requirement that the detailed-route outcome reports the router's own violation counts (final total, per-iteration trajectory, and the final table by type and layer), never a count of report-file entries.

## Impact

- **Code:** `.github/workflows/pnr.yml` (inputs, env wiring, step summary) and `target/ihp13/openroad/scripts/pnr/drt.tcl` (status-line counts). Possibly `docs/pnr-pipeline.md` and `docs/infra-plan.md` Phase 11 (findings).
- **Compute:** Phase 1 is about 3 × 9 h (about $33). Phase 2 is one run of up to the lane's 48 h job ceiling (up to about $58). Every dispatch is approved by the user first.
- **Thesis numbers:** unchanged by this change. They move only in the follow-up that re-runs both sides on the winning settings.
