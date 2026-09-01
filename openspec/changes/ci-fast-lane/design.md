## Context

See proposal.md - Why. Current state that shapes the approach:

- `.github/workflows/docker-image.yml` is the only existing workflow; it builds/publishes `newt-eda` and runs `docker/smoke-test.sh` as a tooling-presence check, but never runs against project RTL/SW. It's a useful pattern reference (container-based jobs, `ubuntu-latest`, path-scoped triggers) but a different job, not something this change extends.
- `newt-eda:dev` on GHCR (Phase 1) already has Verible, Verilator, bender, and the riscv64 toolchain. No new image work needed.
- `bender check` and `verible-verilog-lint` are not invoked anywhere in this repo today — this change is what wires them in for the first time. `iguana.mk` has no "lint changed RTL only" target; `verilator --lint-only` today only runs implicitly as part of `ig-verilator-model` over the whole file list (`target/verilator/verilator.mk`), not scoped to a diff.
- `ig-sw-all` (`iguana.mk:270`) already builds every test binary via the riscv64 toolchain — directly usable for the `sw` job with no new Make targets.
- `main`'s branch protection already requires status checks, currently an empty list, explicitly left that way in Phase 0 pending this change (`docs/infra-plan.md` Phase 0).
- The three stub jobs (`sim-unit`, `sim-soc`, `synth-coproc`) each name a real, already-tracked blocker: `docs/custom-isa-extension.md`'s pending ISA-mechanism decision + no Phase 7 RTL yet (`sim-unit`, `synth-coproc`), and the JTAG-DM protocol bug tracked in `verilator-sim-flow`'s `tasks.md` (3.1) (`sim-soc`).

## Goals / Non-Goals

**Goals:**

- A single workflow file whose job *names* already match the Phase 3 table in `docs/infra-plan.md`, so nothing about the workflow's shape needs to change when Phase 7 or the Verilator blocker land — only each stub job's body does.
- `lint` and `sw` are real, useful checks from the first merge of this change, catching regressions the project has never had automated coverage for.
- Every stub job fails loudly (as a CI *authoring* bug, not silently) if it stops running for an unrelated reason (e.g. a container issue) — the "exit 0" behavior is specific to "the condition it checks for is the known, named blocker," not "anything went wrong, so pass anyway."

**Non-Goals:**

- Actually resolving the `sim-unit`/`synth-coproc`/`sim-soc` blockers — that's Phase 7 and the deferred Verilator DM-bug work, tracked elsewhere.
- Self-hosted runners, Azure, or synth/P&R lanes (Phases 4-6) — out of scope, GitHub-hosted `ubuntu-latest` only.
- A generic "changed files" framework — `lint`'s RTL-diff scoping is intentionally minimal (see D2).

## Decisions

### D1: One workflow file, five jobs, container-based like `docker-image.yml`

`.github/workflows/ci.yml` with `container: ghcr.io/wortexx/newt-eda:dev` set per-job (or at the workflow level if all five jobs need it — they do). Mirrors the existing workflow's use of `ubuntu-latest` + the published image rather than installing tools on the runner directly.

- *Alternative — separate workflow files per job*: rejected; five tiny workflow files split what's conceptually one CI run, complicates the required-checks story, and diverges from this repo's one-workflow-per-concern pattern (`docker-image.yml` is the only precedent, and it's one file).

### D2: `lint` scopes to changed `.sv`/`.svh` files via `git diff`, not the whole tree

`git diff --name-only origin/main...HEAD -- '*.sv' '*.svh'` (PR) or the push's before/after SHA range, feeding both `verible-verilog-lint` and a per-file `verilator --lint-only` (each file compiled standalone against the project's include paths, since a full-elaboration `--lint-only` run needs the complete Bender file list and is already covered at build time by `ig-verilator-model`/`ig-verilator-flist`, not something worth re-running as a per-PR lint step). `bender check` runs unscoped (it validates `Bender.yml`/`Bender.lock` consistency, not per-file).

- *Alternative — lint the entire RTL tree every run*: rejected as the default; the tree includes vendored Bender dependencies under `.bender/` (not linted) and would make `lint` slow and noisy with pre-existing findings in code this change didn't touch. Scoping to the diff keeps the bar "don't introduce new lint errors," which is achievable; "the whole tree is lint-clean" is a separate, larger effort not in scope here.
- *Alternative — full-elaboration `verilator --lint-only` per PR against the whole SoC*: rejected for `lint` specifically (too slow for a fast-lane job, and duplicates what `ig-verilator-model` already does); the full-elaboration lint gate effectively already exists as a side effect of any change that touches `ig-verilator-model` in a future CI job, not this one.

### D3: Stub jobs are real jobs with a real (if narrow) check, not `if: false` no-ops

Each stub job actually runs its precondition check (does coprocessor RTL exist under `hw/`? does the Verilator green-light run pass?) and exits 0 either way for now — printing which branch it took. This is different from disabling the job outright.

- *Alternative — `if: false` / commented-out job*: rejected; doesn't show up in the PR checks list at all, silently reverting to "nothing runs," which is exactly the "job structure needs rework later" problem this change exists to avoid. A visible, named, always-green-for-now job is the whole point.
- *Alternative — mark stub jobs `continue-on-error: true` and let them actually fail internally*: rejected; a job that fails-but-continues still shows a red ✗ in the checks list (only the merge isn't blocked), which is confusing given these are known-and-expected non-conditions, not a caught failure. Exiting 0 directly (with the reason printed) reads as intentional rather than "broken but tolerated."
- How each stub decides its branch: `sim-unit`/`synth-coproc` check `test -d hw/coproc` (or whatever the eventual Phase 7 module path turns out to be — this is the one placeholder that will need a one-line update whenever Phase 7 lands, unavoidable since the path doesn't exist yet) and, if present, run the real check instead of stubbing; `sim-soc` runs `make ig-sim-verilator` for real every time (cheap to just try) and inspects the exit code — a 0 (green light passes) is treated as "the blocker has cleared," logged prominently, but the job *still* exits 0 this run (per the spec's graduation requirement — graduating to gating is a deliberate follow-up, not automatic) rather than silently starting to gate on its own.

### D4: Required-status-check wiring via `gh api`, not the GitHub UI

`gh api repos/{owner}/{repo}/branches/main/protection/required_status_checks -X PATCH -f "contexts[]=lint" -f "contexts[]=sw" ...` (or the equivalent `gh ruleset`/`branch-protection` call already used to set up the existing empty list in Phase 0). Follow whatever Phase 0 actually used — check its commit before writing the tasks step.

- *Alternative — instruct the user to click through Settings*: rejected as the primary path; less reproducible and harder to verify from tasks.md, though documenting the manual equivalent as a fallback is reasonable since this step needs repo-admin permission the automation might not have in this environment.

## Risks / Trade-offs

- [A stub job's "does the blocker still exist" check silently breaks (e.g. the coprocessor path check looks for the wrong directory once Phase 7 actually lands under a different path) → stub never graduates, false confidence] → D3's exit-0-either-way design means this fails safe (never blocks a merge it shouldn't), but could also fail to *notice* a graduation opportunity. Mitigation: each stub's summary output states the exact precondition it checked, so a human glancing at CI output after Phase 7 work notices "still says stub" and investigates.
- [`lint`'s diff-scoping (D2) misses a lint error in a file changed indirectly, e.g. via a Bender target/config change without touching the `.sv` file itself] → accepted; this is the standard trade-off of any diff-scoped lint job, and the alternative (full-tree lint) is a larger, separately-scoped effort per D2.
- [Branch protection API call needs repo-admin token scope this environment/user's `gh` auth may not have] → surfaced explicitly as a task with a manual fallback (GitHub Settings UI), not silently skipped.
