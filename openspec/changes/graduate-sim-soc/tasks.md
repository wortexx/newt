# Tasks

Tags: **[edit]** plain editing · **[eda]** needs the `newt-eda` container (Verilator / riscv64 gcc) · **[ci]** needs a real GitHub Actions run · **[admin]** changes shared repository settings and needs user confirmation. No task needs synth or P&R.

## 1. Verilator lane: CVA6 config guard and buildable test programs

- [x] 1.1 **[edit] [eda]** In `target/verilator/verilator.mk`, add the design D4 guard at the top of the `$(VERILATOR_MODEL)` recipe: fail with `error: CVA6 config not applied - run 'make ig-hw-cva6' (or ig-hw-all) first` unless `$(IG_CVA6_PKG_FILE).orig` exists and differs from `$(IG_CVA6_PKG_FILE)`. Also add `$(IG_CVA6_PKG_FILE)` as a prerequisite of the model. Verify in the container (spec `verilator-sim` "Model is built against the SoC's CVA6 configuration"):
  - **Unconfigured case:** with the package file restored from `.orig` (or `.orig` absent), `make ig-verilator-model` exits non-zero with that message before any `verilator` invocation.
  - **Configured case:** after `make ig-hw-cva6`, the model builds and `make ig-sim-verilator` (helloworld) passes.
  - **No rebuild on binary change:** a second `make ig-sim-verilator BINARY=<other elf>` does not re-verilate (spec: changing the binary does not rebuild the model).

  **Done 2026-10-06** (fresh clone in a Docker volume, `newt-eda:dev`, amd64 emulation on an M3 Max). Unconfigured, `.orig` absent: the guard fires after the flist, before any `verilator --cc` (exit 2). Package restored from `.orig`: same error (exit 2). Configured: the model builds (exit 0) and helloworld passes. Both `ig-sim-verilator` runs after the build invoked `verilator` 0 times, so changing `BINARY` does not re-verilate.
- [x] 1.2 **[eda]** Check that the two programs build by target name from a fresh dependency checkout (empty `.bender/`, then `make ig-hw-cva6`):
  - `make $(bender path cheshire)/sw/tests/helloworld.spm.elf`
  - `make sw/tests/sha3_smoke.spm.elf`

  Verify that both ELFs exist and `riscv64-unknown-elf-readelf -h` reads them. If either target misses a prerequisite (generated headers, `libcheshire.a`, `libnewt.a`), use `make ig-sw-all` in the workflow instead (design D1 fallback) and record which one was chosen and why in this task.

  **Done 2026-10-06** (same fresh clone, after `make ig-hw-cva6`). `make $(bender path cheshire)/sw/tests/helloworld.spm.elf` and `make $PWD/sw/tests/sha3_smoke.spm.elf` both build, and `readelf -h` reads them (ELF64 RISC-V, entry `0x10000000`). **The relative spelling `make sw/tests/sha3_smoke.spm.elf` fails**: the project rules are keyed on the absolute `$(IG_ROOT)/sw/tests/...` path, so the relative target falls through to Cheshire's generic pattern rule without the project include dirs or `libnewt.a` (missing header). **Chosen:** build both by absolute target in the workflow, no `ig-sw-all` fallback needed.
- [x] 1.3 **[eda]** With the configured model, run both programs locally:
  - `make ig-sim-verilator BINARY=<abs path>/sha3_smoke.spm.elf`
  - the same for helloworld

  Verify that each exits 0 and prints its PASS line. Record each program's `[TB] Test PASSED (... N sys-clock cycles)` count here. These are the inputs to design D3's timeouts.

  **Done 2026-10-06** (local, amd64 emulation): helloworld `Test PASSED (exit code 0, 216760 sys-clock cycles)`, 86 s; sha3_smoke `sha3_smoke: PASS (0 failures)`, `Test PASSED (exit code 0, 616928 sys-clock cycles)`, 240 s. Model build 1264 s (Verilator walltime 1257 s, bld 1194 s, 1 thread). Timeouts (D3, ~5x rounded up): helloworld 1,200,000; sha3_smoke 3,200,000.
- [x] 1.4 **[edit]** In `target/verilator/README.md`:
  - add `make ig-hw-cva6` (or `ig-hw-all`) as a prerequisite in "Building and running", and name the guard's error message;
  - add a short "In CI" note: `sim-soc` runs helloworld + `sha3_smoke` on every PR and is a required check.

  Verify that the documented command sequence runs as written from a fresh checkout (same run as 1.2/1.3).


  **Done 2026-10-06.** Verified against the same fresh-clone run: `ig-hw-cva6`, then the model, then `ig-sim-verilator` for both programs. The ELFs were built by target, not `ig-sw-all`; the `sw` job runs `ig-sw-all` from a fresh checkout on every PR.
## 2. Rewrite the `sim-soc` job

- [x] 2.1 **[edit]** Rewrite `sim-soc` in `.github/workflows/ci.yml` per design D1–D3:
  - **Steps:** checkout → `safe.directory` → `make ig-hw-cva6` inside the existing `retry` helper (the only retried step) → build the two ELFs (per 1.2's outcome) → `make ig-verilator-model` (`id: model`) → one run step per program with `make ig-sim-verilator BINARY=<absolute path> TIMEOUT_CYCLES=<≈5× task 1.3's count, rounded up>`.
  - **Run-step condition:** each run step has `if: ${{ !cancelled() && steps.model.outcome == 'success' }}`.
  - **Job timeout:** `timeout-minutes: 30`.
  - **Comments:** remove the stub's "always exits 0" logic and its warning/stub echo lines. Update the workflow header comment to say all five fast-lane jobs are real and gating, and that no job is stubbed.

  Verify:
  - YAML parses (`python3 -c 'import yaml,sys; yaml.safe_load(open(".github/workflows/ci.yml"))'`).
  - `actionlint .github/workflows/ci.yml` is clean if available.
  - No step other than the `ig-hw-cva6` one contains `retry`.

  **Done 2026-10-06.** YAML parses (PyYAML via `uv run`). `actionlint` (`rhysd/actionlint` image) reports only two info-level shellcheck notes in the `lint` job's existing step, identical on `main`; none in `sim-soc`. Within `sim-soc`, `retry` appears only in the `ig-hw-cva6` step. Also updated the `lint` job comment that called `sim-soc` "not-yet-gating". The ELFs are built by absolute target (1.2) and passed to the run steps through `$GITHUB_ENV`. The header comment's hosted-runner numbers are `<TBD>` until 2.2.
- [ ] 2.2 **[ci]** Push the branch and open the PR. Verify on the PR's own run that `sim-soc` passes, with both programs' PASS lines in their own step logs. Record here: the model-build wall time, each program's cycle count and wall time on `ubuntu-latest`, and the total job time. Write the same numbers into the workflow comment from 2.1. If a program's hosted-runner cycle count differs from 1.3, re-derive its `TIMEOUT_CYCLES` from the hosted value.
- [ ] 2.3 **[ci]** Show that the job gates on real failures (spec `ci-pipeline` "Missing test program is a failure, not a retry" and "SoC boot regression fails sim-soc"). On a throwaway commit on the PR branch, point one run step's `BINARY` at a non-existent path. Verify:
  - `sim-soc` fails on that step on the first attempt;
  - the model is not rebuilt;
  - the other program's step still runs;
  - the log contains no mention of the JTAG-DM blocker.

  Then revert the commit and confirm the job is green again.

## 3. Graduate to a required check and update the plan

- [ ] 3.1 **[admin]** After 2.2/2.3 are green and with the user's confirmation, set `main`'s required status checks to exactly `lint`, `sw`, `sim-unit`, `synth-coproc`, `sim-soc`, keeping `enforcement_level` `non_admins` (design D6; the PATCH replaces the whole list). Verify that `gh api repos/wortexx/newt/branches/main --jq '.protection.required_status_checks.contexts'` returns those five names (spec `ci-pipeline` "Required list matches the gating jobs").
- [ ] 3.2 **[edit]** Update `docs/infra-plan.md`:
  - Phase 3: check off the `sim-soc` item with the date, the PR, and the measured job time from 2.2. Replace the "~25 min model build" budget with the measured hosted figure, noting that 25 min was local emulation.
  - Phase 2: close the two stray unchecked items (unit TB delivered in Phase 7; the hyperbus fallback is moot).
  - Phase 0's "Still open" note: record that `wt_axi_adapter2.patch`'s Verilator consumer now runs in CI on every PR.

  Verify by re-reading Phase 3 that no sentence still calls `sim-soc` a stub or blocked.
- [x] 3.3 **[edit]** Verify that `openspec validate graduate-sim-soc --strict` passes, and that `AGENTS.md`'s CI-lanes table still describes the fast lane correctly. It names jobs only generically, so no edit is expected; confirm and note it here.

  **Done 2026-10-06.** `openspec validate graduate-sim-soc --strict` passes. **Contrary to the expectation above, `AGENTS.md` did need an edit:** its fast-lane row read "Fast lane (lint, sw, sim stubs)", which is wrong now that no job is stubbed. Changed to "Fast lane (lint, sw, unit + SoC sim, coprocessor synth)". The rest of the table is still accurate.
