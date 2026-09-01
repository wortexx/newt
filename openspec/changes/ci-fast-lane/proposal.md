## Why

Every push and PR today runs zero automated checks against RTL, software, or synthesizable coprocessor code — `docker-image.yml` only rebuilds the tooling image itself. `docs/infra-plan.md` Phase 3 calls this out as the first CI lane to stand up once a free simulator exists (Phase 2). Phase 2 delivered the Verilator build/run infrastructure, but its own green-light run is still blocked on an open JTAG-DM protocol bug (deferred, not gating further infra work — see `openspec/changes/verilator-sim-flow`'s `tasks.md`/`design.md`), and the coprocessor RTL that two more Phase 3 jobs are meant to exercise doesn't exist yet (Phase 7, still pending the CV-X-IF-vs-`Zknh` decision). Standing up the whole job structure now — real checks where inputs already exist, explicit non-gating stubs where they don't — means the workflow and required-status-check list don't need reworking later, and regressions in what already works (lint, sw build) start getting caught immediately instead of waiting on two more phases to land first.

## What Changes

- Add `.github/workflows/ci.yml`: triggers on every PR and push, runs in the `newt-eda` container on `ubuntu-latest`, with five jobs matching `docs/infra-plan.md`'s Phase 3 table:
  - `lint` — `bender sources` (dependency graph resolves/is consistent) + `verible-verilog-lint` + `verilator --lint-only` on changed RTL. **Real, blocking from day one.**
  - `sw` — build the existing test binaries (`make ig-sw-all`, riscv64 gcc). **Real, blocking from day one.**
  - `sim-unit` — coprocessor unit testbench against the NIST KAT set. **Stub**: no coprocessor RTL exists yet (Phase 7 not started); the job runs, prints why it has nothing to do, and exits 0 (non-gating) rather than being silently absent from the workflow.
  - `sim-soc` — Verilator SoC boot + a KAT test through the new instructions. **Stub**: gated on the still-open JTAG-DM blocker from Phase 2; the job attempts `make ig-sim-verilator` against the existing green-light test and reports the known-blocked outcome without failing the run.
  - `synth-coproc` — yosys synth of the coprocessor module only, area/Fmax vs. a checked-in budget. **Stub**: no coprocessor module exists yet; same non-gating pattern as `sim-unit`.
- Wire the two real job names (`lint`, `sw`) into `main`'s branch protection as required status checks, per the placeholder Phase 0 already left for this (`docs/infra-plan.md` Phase 0: "status checks required-but-empty (add Phase 3 job names once CI exists)"). The three stub jobs are intentionally **not** added as required checks — they cannot fail the build by design while stubbed, so requiring them would be a no-op that hides their real purpose once they go live.
- Each stub job's summary output states its own blocking condition explicitly (which task/phase unblocks it), so a reader of a CI run — not just this planning record — can see why it's a no-op.

## Capabilities

### New Capabilities

- `ci-pipeline`: what runs automatically on every push/PR — which checks are real and gating today, which are scaffolded-but-non-gating pending a named blocker, and what "real" vs "stub" means operationally (exit codes, required-check wiring, how a stub graduates to real once its blocker clears).

### Modified Capabilities

_None._ This change adds automation around existing build/lint/sim/synth entry points (`iguana.mk`, `verible`, `verilator`, `yosys.mk`); it does not change what any of those flows themselves require or produce.

## Impact

- **CI:** new `.github/workflows/ci.yml`. Existing `.github/workflows/docker-image.yml` untouched.
- **Build system:** no changes — the workflow calls existing `iguana.mk`/`verilator.mk`/`yosys.mk` targets; if a target needed by `lint` or `sw` doesn't exist yet (e.g. no dedicated "lint changed RTL only" target), this change adds the minimal wiring for it (documented in design.md), not new build logic.
- **Repository settings:** `main` branch protection required-status-checks list gains `lint` and `sw` (via GitHub settings or `gh api`, whichever the repo already uses — Phase 0 set the existing protection up, follow its pattern).
- **Dependencies:** none added — `verible-verilog-lint` and `verilator` are already in `newt-eda` (Phase 1); no new tools.
- **Risk:** stub jobs must be unambiguous about their non-gating status in the GitHub UI (job name, summary text, exit code 0) so nobody mistakes a green stub for a passing check it isn't.
