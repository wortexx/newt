# Proposal

## Why

The `sim-soc` CI job is still a non-gating stub, but the blocker it was waiting for, the Verilator JTAG-DM bug, cleared on 2026-10-06 (`verilator-sim-flow`, archived). The `ci-pipeline` spec requires a deliberate follow-up change to graduate it. So far nothing in CI boots the whole SoC: `sim-unit` covers the coprocessor blocks only, and a break in SoC integration, boot, the CV-X-IF hookup or the Verilator harness would merge unnoticed.

The stub also cannot pass as written, whatever the RTL does. Its first run after the green light (run `37392085594`, `main` @ `9385a09`) built the model in ~4 min and then failed with `[ELF] ERROR: cannot open sw/tests/helloworld.spm.elf`. The job never builds the test binaries, and the path it passes is not where the ELF lives (`$(CHS_ROOT)/sw/tests/`). Its retry loop then treated that real failure as checkout flakiness, rebuilt the model twice more, and reported the old JTAG-DM blocker as the likely cause. Graduating means turning the stub into a real test, not just flipping its exit code.

## What Changes

Flow stages touched: **CI** and **sim** (the Verilator lane's build rules). No change to RTL, sw sources, synth or backend.

- `sim-soc` in `.github/workflows/ci.yml` becomes a real job:
  - It prepares the SoC configuration (`make ig-hw-cva6`), builds the test binaries it runs and the Verilator model, then runs them.
  - It runs `helloworld.spm.elf` (platform boot: JTAG preload, UART, exit-code path) and `sha3_smoke.spm.elf` (SHA3-256 KAT through both CV-X-IF ISE back-ends). This matches the Phase 3 plan: "Cheshire boot + one KAT through the new instructions".
  - It exits non-zero if any run fails, times out or cannot start.
- The checkout retry is limited to the dependency checkout step, as in `sim-unit` and `synth-coproc`. A failed build or simulation is never retried and never attributed to the retired blocker.
- `sim-soc` is added to `main`'s required status checks, after it has been seen green on this change's own PR.
- **Verilator lane fix:** `ig-verilator-model` refuses to build when the CVA6 configuration rewrite (`ig-hw-cva6`) has not been applied. Without it, the model silently simulates stock CVA6 package parameters rather than the SoC's (e.g. scoreboard depth, which also sets the CV-X-IF id width). A fresh CI checkout hits exactly this. The stub's build on `main` used stock parameters.
- Docs: `ci.yml`'s header comment, `docs/infra-plan.md` Phase 3, and a CI note in `target/verilator/README.md`.

Not in scope:

- Model caching: the measured hosted-runner build is ~4 min, not the ~25 min seen under local emulation.
- The full 40-vector KAT suite in CI, MMIO-arm tests, and the odd-exit-code fix (Phase 16).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `ci-pipeline`: `sim-soc` moves from the stubbed-jobs requirement to gating. That requirement is replaced by a generic one for any future stub, because all three jobs it named have now graduated. The graduation requirement gains `sim-soc`'s concrete real condition (which programs, what counts as failure, hosted runner only). The required-status-checks requirement is updated to the actual gating set (`lint`, `sw`, `sim-unit`, `synth-coproc`, `sim-soc`). It still names only `lint` and `sw`, although `sim-unit` and `synth-coproc` already gate live.
- `verilator-sim`: a new requirement that the model is built against the SoC's CVA6 configuration and that the build fails clearly when that configuration has not been applied.

## Impact

- `.github/workflows/ci.yml`: `sim-soc` job rewritten. Expected wall time is ~10–12 min on `ubuntu-latest`: checkout and deps, SW build, ~4 min model build, two runs. This runs in parallel with the other jobs, so the fast lane's critical path grows only if `sim-soc` becomes the slowest job (today that is `sw`/`sim-unit` at ~5 min).
- `target/verilator/verilator.mk`: a precondition check on the CVA6 config rewrite. Developers building the model locally now need `make ig-hw-cva6` (or `ig-hw-all`) first, and the error message says so.
- GitHub branch protection on `main`: one more required context. Applying it needs repo-admin rights.
- Docs: `docs/infra-plan.md` Phase 3, `target/verilator/README.md`, the `ci.yml` header.
