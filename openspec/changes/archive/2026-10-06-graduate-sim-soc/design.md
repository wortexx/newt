# Design

## Context

See proposal.md (Why) for the motivation. This section covers only the current state that shapes the approach.

- **Current `sim-soc` job** (`.github/workflows/ci.yml`): a single step wraps `make ig-sim-verilator BINARY=sw/tests/helloworld.spm.elf` in the 3-attempt `rm -rf .bender` retry used for the flaky buildroot submodule clone, and always exits 0.
- **The stub's run on `main`** (`37392085594`): the model built in **227 s** (`verilator: Walltime 226.948 s`, bld 205 s, single-threaded). Then `[ELF] ERROR: cannot open sw/tests/helloworld.spm.elf`. The retry repeated the whole sequence twice. Total job time was 9.5 min, of which ~6 min was wasted.
- **Where the binaries live:**
  - `helloworld.spm.elf` is a Cheshire test, `$(CHS_ROOT)/sw/tests/helloworld.spm.elf`, built by Cheshire's `sw.mk` pattern rules (the Makefile's own `BINARY ?=` default).
  - `sha3_smoke.spm.elf` is a project program, `sw/tests/sha3_smoke.spm.elf`, built by `sw/sw.mk` through the same rules plus `libnewt.a`.
  - Neither is tracked in git. The `sw` job builds them, but in its own container, and passes nothing on.
- **CVA6 configuration:**
  - `ig-hw-cva6` (`iguana.mk`) rewrites `$(IG_CVA6_PKG_FILE)` in the CVA6 checkout in place. On first use it saves the pristine file as `$(IG_CVA6_PKG_FILE).orig`.
  - `ig-verilator-model` does not depend on it. A fresh CI checkout therefore verilates stock package parameters.
  - `sim-unit` already runs `make ig-hw-cva6` first, because the scoreboard depth sets the CV-X-IF id width. The local green light ran on a checkout where the rewrite had been applied earlier.
- **Simulation speed:** `helloworld` ends after 216,760 sys-clock cycles, ~2 min wall-clock under amd64 emulation on an M3 Max. Native hosted-runner speed and `sha3_smoke`'s cycle count have not been measured. The default `+TIMEOUT_CYCLES` is 20 M, about 90× helloworld's runtime, so a hang could run long enough to hit the job timeout before the simulation's own timeout.

## Goals / Non-Goals

**Goals:**
- A failure in `sim-soc` names the step that failed: deps, config, sw build, model build, or a specific program's run.
- A hung simulation fails within minutes, through the simulator's own timeout and not the job timeout.

**Non-Goals:**
- Sharing build outputs (ELFs, model) between jobs, or caching across runs.
- Changing `newt_tb.cpp`, the RTL, or any test program.
- Regenerating the rest of `ig-hw-all` (bootrom, FMA config, conf JSON). The model already builds and passes from checked-in sources. Only the CVA6 package rewrite changes simulated behaviour unseen.

## Decisions

### D1. The job builds everything it runs, in separate steps

Steps in order:
1. checkout, then `safe.directory`;
2. `make ig-hw-cva6` inside the existing retry helper. This is the first `make` in a fresh workspace, so it absorbs the flaky dependency checkout, exactly as in `sim-unit`;
3. build the two ELFs by their Make targets;
4. `make ig-verilator-model`;
5. one step per program running `make ig-sim-verilator BINARY=<abs path> TIMEOUT_CYCLES=<n>`.

Only step 2 is retried.

Each run step uses `if: ${{ !cancelled() && steps.model.outcome == 'success' }}`, so a `helloworld` failure still lets `sha3_smoke` report. The job still fails if either run fails.

*Alternatives:*
- Download the `sw` job's ELFs as an artifact (`needs: sw`). This serializes the two jobs, adding ~4 min to the critical path, and couples them, all to save ~1–2 min of compiling.
- `make ig-sw-all`: builds all ~20 Cheshire and project programs where two are needed. It is a fallback if the two targets turn out not to pull in their prerequisites (generated headers, `libcheshire.a`, `libnewt.a`). Task 1.2 checks this.

### D2. Test set: `helloworld.spm` + `sha3_smoke.spm`

`helloworld` is the spec's green-light program and covers boot, JTAG preload, the UART and the exit-code path. `sha3_smoke` covers what the SoC adds: SHA3-256("abc") through both CV-X-IF ISE back-ends, so CVA6 → CV-X-IF → `keccak_cvxif` is exercised end to end. Both passed on the local model on 2026-10-06. Both use even exit codes (`newt_exit_code`), so Phase 16's odd-code hang cannot mask a failure.

*Alternatives:*
- `sha3_kat_ise` (40 NIST vectors): far more cycles, and `sim-unit` already checks the KATs at block level. Kept local/Xcelium.
- `sha3_kat_mmio`: the MMIO arm is not a CV-X-IF integration path and `sim-unit` covers it. Can be added later if a cheap one exists.

### D3. Explicit, measured `TIMEOUT_CYCLES` per program

Each run step passes `TIMEOUT_CYCLES` set to about 5× that program's measured cycle count on the hosted runner, rounded up (helloworld: 216,760 → ~1.2 M). A hang then fails in roughly 5× a normal run's time. The job gets `timeout-minutes: 30` as a backstop above the expected ~10–12 min. The measured cycles and wall time per program go in the workflow comment, so a later slowdown can be compared against them.

*Alternative:* keep the 20 M default. A hang could then run past the job timeout, and the failure would read "job cancelled" without naming the program.

### D4. Guard in `verilator.mk`, not an implicit `ig-hw-cva6` dependency

The `$(VERILATOR_MODEL)` recipe first checks that `$(IG_CVA6_PKG_FILE).orig` exists and that `$(IG_CVA6_PKG_FILE)` differs from it. If either check fails it exits with `error: CVA6 config not applied - run 'make ig-hw-cva6' (or ig-hw-all) first`. `$(IG_CVA6_PKG_FILE)` also becomes a prerequisite of the model, so re-applying a changed configuration rebuilds the model.

*Alternative:* make the model depend on `ig-hw-cva6`. That target is phony and rewrites the file on every call, so the ~4 min model would rebuild on every `make ig-sim-verilator`, breaking the spec's "changing the binary does not re-verilate". The guard also catches a developer's stale local tree, not only CI.

### D5. No model cache

At 227 s on a hosted runner, a cache would save ~3 min per run. It would also bring a cache-key design: the flist's inputs, every RTL file in the Bender closure, the CVA6 rewrite, and Verilator's version. A wrong key would hide a stale model, which is the failure that matters. Revisit if the job becomes the fast lane's critical path for real. The ~25 min figure in `docs/infra-plan.md` was local emulation and gets corrected there.

### D6. Branch protection updated last, from the PR's own green run

`sim-soc` is added to `main`'s required contexts only after the rewritten job has passed on this change's PR. The PATCH replaces the whole contexts list, so the call sends all five names (`lint`, `sw`, `sim-unit`, `synth-coproc`, `sim-soc`), and `enforcement_level: non_admins` is kept. The current token cannot read `/branches/main/protection` (404), so this step needs repo-admin credentials or the user. It changes shared repository state, so it is a user-confirmed step. Open PRs are unaffected: their own `sim-soc` is the old stub, which exits 0.

## Risks / Trade-offs

- [Native simulation is slower than expected and the job exceeds ~15 min] → It runs in parallel, so it delays merge but blocks nothing else. If it becomes the slowest job by a wide margin, drop to `helloworld` + `sha3_smoke`'s ISE-only half, or revisit D5.
- [The `.orig` guard is a proxy, so a hand-edited package file passes it] → Accepted. It catches the real failure, a fresh or reset checkout. `sim-unit` relies on the same rewrite.
- [Building ELF targets directly misses a prerequisite in a fresh tree] → Task 1.2 checks this from a clean `.bender/` locally. Fall back to `ig-sw-all` (D1).
- [The flaky buildroot clone now fails `sim-soc` after 3 attempts, where the stub swallowed it] → This matches `sw`, `sim-unit` and `synth-coproc`, which already gate on the same retry. It is not a new exposure.
- [Verilator's ~29 UNOPTFLAT and SPECIFYIGN warnings flood the log (~9,500 lines in the stub run)] → Cosmetic. Separate steps keep each program's output in its own collapsible group. Silencing warnings is out of scope.

## Migration Plan

1. Land the `verilator.mk` guard and the workflow rewrite on one PR. The PR's own `sim-soc` run is the acceptance test.
2. Once that run is green, the user (or an admin token) adds `sim-soc` to the required contexts (D6), then merges.
3. Rollback: remove `sim-soc` from required contexts. The workflow change can then be reverted on its own. The guard has no reason to roll back.

## Open Questions

- Exact `TIMEOUT_CYCLES` values and per-program wall time on `ubuntu-latest`. These are measured during implementation (task 2.2) and do not change the approach.
