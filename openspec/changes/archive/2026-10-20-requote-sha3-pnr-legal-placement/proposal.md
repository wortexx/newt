# Proposal

## Why

The thesis's SoC place-and-route comparison (`docs/results/sha3-ppa.md` "SoC place and route", `docs/results/sha3-evaluation.md` "Timing") is quoted from two runs whose placements were not legal: after `cts`, 1.5 % of cells overlapped in the reference (`37108127061`) and 1.0 % with both arms (`37162759719`). Both runs also predate three flow changes:

- `use-diamond-legalizer`: legality is a gated check;
- the default die enlarged to `die_scale` 1.10;
- `keep-cells-out-of-macro-margins`: macro margins blocked, routability inflation 2.5.

Legality alone moves the result a lot. On the enlarged die, `grt` WNS went from −8.23 ns to −13.12 ns before the margin fix. Both results docs carry a "requoting these figures from legal placements is a separate decision" caveat. The user decided on 2026-10-14 to requote now: the SHA-3 work is complete, and the next planned frontend change (`replace-svase-sv2v-with-read-slang`) would otherwise mix a netlist change into the comparison.

## What Changes

- **Both-arms side: reuse probe B, no new run.** Run `38395368038` (branch `gpl-inflation-probe`, `3fdacef`) differs from `main` (`a416399`) in flow and RTL by comments only. It ran the full flow to `grt` with today's defaults, and every gated stage passed, legality included. Its `pnr-reports` artifact expires 2026-11-12, so it is saved first.
- **Reference side: one new run on today's flow.** Run it from a throwaway branch off `main` that removes only the SHA-3 hardware and restores the pre-coprocessor SoC configuration:
  - CV-X-IF off;
  - no external AXI subordinate;
  - no Keccak instances;
  - no Keccak keep-hierarchy selectors.

  Synthesize it on the synth lane, then run P&R with `stop_after=grt` and default inputs. The branch is never merged.
- **Check the reference netlist against the old one.** The synth metrics must match the old pre-coprocessor reference (`36447894410`) within the ABC noise band, so "reference" still means the same hardware.
- **Regenerate the results.** `scripts/sha3_ppa.py` regenerates `docs/results/sha3-ppa.md`. Its hard-coded flow description changes: enlarged die, legal placement, margin blocking. Text that only held for the old runs goes. Every energy figure derived from the achieved period regenerates.
- **Rewrite the hand-written prose.** `docs/results/sha3-evaluation.md`'s timing and energy prose gets the new figures. The old illegal-placement figures stay in it as a dated superseded row, so the effect of legality and the flow changes stays visible.
- **Close the item in the plan.** Tick the requote item in `docs/infra-plan.md` Phase 11.

Flow stages touched: **synth** (one synth-lane run, reference branch only), **backend** (one P&R-lane run, reference branch only), **RTL** (on the throwaway branch only, never on `main`), and docs and the report generator. No change to `main`'s RTL, sim, CI or sw.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `sha3-evaluation`: one new requirement. SoC P&R figures compared between the reference and the SHA-3 build must come from placements that passed the gated legality check. Both sides must use the same flow revision and die, and the report must state both. Superseded figures from illegal placements may only appear labelled as such.

## Impact

- **Code on `main`:**
  - `scripts/sha3_ppa.py`: P&R section text, its legality and die statements, and the power paragraph;
  - `docs/results/sha3-ppa.md` (regenerated);
  - `docs/results/sha3-evaluation.md`;
  - `docs/infra-plan.md`.
- **Throwaway branch only:** `hw/iguana_pkg.sv`, `hw/iguana_soc.sv`, `target/ihp13/yosys/project-synth.mk`.
- **Compute:** one synth (~2 h) and one P&R to `grt` (~6–7 h) on the self-hosted VM, roughly $10–12. Both are dispatched only after the user approves.
- **Thesis numbers:** the achieved period, and therefore every energy-per-byte figure at it, moves. Probe B's WNS of −8.96 ns gives about 19.96 ns against the 19.23 ns quoted today. Synthesis-stage and block-level figures do not change.
