## Context

- `apm.yml` (`targets: [claude]`) and `apm.lock.yaml` already fully describe 12 `github/awesome-copilot` dependencies and exactly which files `apm install` writes under `.claude/` (`deployed_files` + sha256 hashes per dependency in the lockfile).
- Those apm-managed paths are currently *untracked*: `.claude/agents/`, `.claude/rules/`, and 7 `.claude/skills/*` directories (`az-cost-optimize`, `azure-deployment-preflight`, `azure-pricing`, `azure-well-architected-review`, `docs-sync-audit`, `github-actions-efficiency`, `github-actions-hardening`). Nothing needs to be un-committed — this is purely additive before they're ever staged.
- `.claude/commands/opsx/*` and `.claude/skills/{openspec-*,systemverilog-style}/` are hand-authored and already git-tracked; they are not in `apm.lock.yaml` and must stay tracked.
- `.gitignore` already ignores `apm_modules/` (apm's package cache) but has no `.claude/`-related entries yet.
- The `apm` CLI is a Homebrew formula (`/opt/homebrew/bin/apm`), not vendored in-repo.
- Makefile convention in this repo: root-level `.mk` files (`iguana.mk`, `tools.mk`) included from the top-level `Makefile`; no `mk/` subdirectory. `tools.mk`'s existing `tools.log` target only *checks* `which $(TOOL)` for each EDA tool — it does not install anything.
- No `.github/workflows/*.yml` references `.claude/` or `apm`. See proposal.md for the full motivation.

## Goals / Non-Goals

**Goals:**
- One command (`make apm`) to (re)materialize apm-managed `.claude/` content from the committed lockfile.
- Stop apm-managed `.claude/` content from being committed, without touching hand-authored `.claude/` content.

**Non-Goals:**
- Auto-installing the `apm` CLI itself (Homebrew, npm, etc.) — out of scope; `make apm` only checks for it.
- Wiring `make apm` into CI — no workflow currently needs `.claude/` content present, so there's nothing to integrate.
- Pinning `github/awesome-copilot` dependencies to a specific ref/sha — that's a pre-existing, separate concern (apm already warns about unpinned deps) and unrelated to this change's scope.
- Restructuring `apm.yml`/`apm.lock.yaml` contents — this change only decides what's tracked, not what's installed.

## Decisions

### D1: Gitignore the apm-managed paths precisely, not all of `.claude/`
List `.claude/agents/`, `.claude/rules/`, and the 7 specific apm-declared skill directories individually in `.gitignore`, rather than a blanket `.claude/` (or `.claude/skills/`) ignore.
**Alternative considered**: ignore all of `.claude/skills/` — rejected because it would also hide the hand-authored `openspec-*` and `systemverilog-style` skills, which must stay tracked and reviewable.
**Trade-off accepted**: the `.gitignore` list must be kept in sync by hand if `apm.yml`'s dependency set changes (e.g. a new skill added later needs a new `.gitignore` line). This is a minor, low-frequency maintenance cost, judged acceptable versus the risk of a blanket ignore silently swallowing hand-authored files.

### D2: `make apm` fails with a guard, doesn't auto-install the CLI
`apm.mk`'s `apm` target starts with a `command -v apm >/dev/null || { ...helpful message...; exit 1; }` guard.
**Alternative considered**: have the target `brew install apm` automatically if missing — rejected as inconsistent with this repo's existing `tools.mk` convention (check-only, never installs), and because silently invoking Homebrew from a Makefile target is a surprising side effect for a hardware-thesis repo that otherwise controls its toolchain explicitly (Docker image, pinned Bender deps).

### D3: New capability `agent-tooling`, not folded into an existing one
None of `ci-pipeline`, `eda-tooling-image`, or `pnr-flow` (the only existing spec capabilities) cover local dev/agent tooling — they're all EDA/CI-flow specific. Introducing `agent-tooling` keeps this concern separate and matches the repo's terse, purpose-named capability style.
**Alternative considered**: a broader `dev-tooling`/`dev-environment` capability — rejected as premature; nothing else (e.g. Docker/Bender setup) is spec-tracked today, and a more general capability can be introduced later if that changes.

## Risks / Trade-offs

- **[Risk]** A contributor forgets to run `make apm` after cloning and is missing Claude Code agents/skills. → **Mitigation**: README setup note; no functional impact elsewhere since no build/test/CI path depends on `.claude/` content being present.
- **[Risk]** `.gitignore`'s explicit skill list drifts from `apm.yml`'s `dependencies.apm` list over time (new dependency added, `.gitignore` line forgotten) → **Mitigation**: low-cost to fix (a `git status` after `apm install` immediately shows the leak); accepted per D1 rather than solved with tooling in this change.

## Migration Plan

1. Add `apm.mk` (new file) with the guarded `apm` phony target.
2. Add `include apm.mk` to the top-level `Makefile`.
3. Add the apm-managed path entries to `.gitignore`.
4. Add the `make apm` setup note to `README.md`.
5. Verify: delete the currently-untracked apm-managed directories, run `make apm`, confirm they're regenerated identically and `git status` shows them as ignored (not untracked).

No rollback concerns: every step is additive/config-only and reversible by reverting the diff; no data migration or irreversible action is involved.
