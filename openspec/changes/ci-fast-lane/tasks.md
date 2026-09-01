# Tasks — CI Fast Lane

Tool legend: **[edit]** = plain file editing, verifiable without EDA tools; **[eda]** = needs the `newt-eda` container (Verilator/bender/riscv toolchain), can be validated locally with `docker run` before pushing; **[gh]** = needs GitHub repo-admin access (branch protection). No synth/P&R runs anywhere in this change.

## 1. Workflow scaffold

- [ ] 1.1 **[edit]** Create `.github/workflows/ci.yml`: `on: [push, pull_request]`, `container: ghcr.io/wortexx/newt-eda:dev`, `runs-on: ubuntu-latest`, five jobs (`lint`, `sw`, `sim-unit`, `sim-soc`, `synth-coproc`) each with a checkout step and a placeholder `echo "TODO"` body. Verify: workflow YAML is valid (`gh workflow view` or a YAML linter) and a pushed commit shows all five job names appear as pending/running checks on the commit/PR.

## 2. Real jobs

- [ ] 2.1 **[eda]** Implement `lint`: `bender sources` (the real dependency-graph-consistency check — `bender check`, named in this task's original draft and in `docs/infra-plan.md`'s Phase 3 table, does not exist in any bender version; found via a real CI failure, see completion note); for changed `.sv`/`.svh` files (`git diff --name-only` against the PR base or push before-SHA, per design.md D2), run `verible-verilog-lint` and a per-file `verilator --lint-only`. Non-zero exit on any error-level finding from any of the three. Verify locally first: `docker run --rm -v $PWD:/work -w /work ghcr.io/wortexx/newt-eda:dev bash -c '<lint commands>'` against a clean checkout (exits 0) and against a deliberately introduced lint error (exits non-zero).
- [ ] 2.2 **[eda]** Implement `sw`: `make ig-sw-all` inside the container (same bender-checkout host-workaround noted in `verilator-sim-flow`'s tasks.md if run on this dev machine; not expected to matter on a GitHub-hosted Linux runner). Non-zero exit on build failure. Verify locally: clean build exits 0; a deliberately broken `sw/tests/*.c` file exits non-zero with the compiler error visible.

## 3. Stub jobs

- [ ] 3.1 **[edit]** Implement `sim-unit` stub: check for the (not-yet-existing) coprocessor RTL/testbench path; if absent, print "stub: pending Phase 7 coprocessor RTL (docs/infra-plan.md Phase 7)" and exit 0; if present, run the real unit-test target instead (leave a clear `# TODO once Phase 7 lands:` comment naming what that target should be, since it doesn't exist yet). Verify: job runs on a PR today, exits 0, and the stub message is visible in the job log.
- [ ] 3.2 **[eda]** Implement `sim-soc` stub: run `make ig-sim-verilator` for real (against `sw/tests/helloworld.spm.elf`, `BOOTMODE=0 PRELMODE=0`) every time; if it exits non-zero, print "stub: pending verilator-sim-flow JTAG-DM blocker (task 3.1) — ran for real, did not pass, not gating yet" and exit 0 regardless; if it exits 0, print "green light passing — ready to graduate this job, see design.md D3" and still exit 0 (graduation is a deliberate follow-up per the spec, not automatic). Verify: job runs on a PR today, exits 0, and the log clearly states which branch it took.
- [ ] 3.3 **[edit]** Implement `synth-coproc` stub: same pattern as 3.1 (check for a coprocessor module path, stub-and-exit-0 if absent). Verify: job runs on a PR today, exits 0, stub message visible.

## 4. Branch protection

- [ ] 4.1 **[gh]** Add `lint` and `sw` to `main`'s required status checks (`gh api repos/{owner}/{repo}/branches/main/protection` or the GitHub Settings UI if the token lacks admin scope — document whichever path was actually used). Verify: `gh api repos/{owner}/{repo}/branches/main/protection/required_status_checks` shows `contexts` containing exactly `lint` and `sw`, not the three stub job names.
- [ ] 4.2 **[edit]** Update `docs/infra-plan.md` Phase 0's branch-protection line and Phase 3 section: check off delivered items, note which jobs are real vs. stubbed and why, record the exact required-status-checks list. Verify: doc reflects reality post-implementation.

## 5. Documentation & closeout

- [ ] 5.1 **[edit]** Add a short note to the top-level README or `.github/workflows/ci.yml`'s header comment explaining the stub-job convention (why a green `sim-soc`/`sim-unit`/`synth-coproc` doesn't mean what it will once Phase 7/the Verilator blocker land), so a future reader of a green PR isn't misled. Verify: comment present and accurate.
