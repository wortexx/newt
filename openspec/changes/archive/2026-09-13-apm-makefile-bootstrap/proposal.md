## Why

The project now depends on `apm` (Agent Package Manager) to pull Claude Code agents, skills, and rules from `github/awesome-copilot`, fully described by `apm.yml` and `apm.lock.yaml`. The files `apm install` writes under `.claude/agents/`, `.claude/rules/`, and several `.claude/skills/*` directories are regenerable, upstream-sourced content — not authored in this repo — and are currently sitting untracked in the working tree, about to be committed by accident. Committing them would bloat the repo with content that a lockfile already fully describes, and that will drift out of sync with `apm.lock.yaml` the moment someone runs `apm update` without re-committing. This change touches **build tooling only** (`Makefile`, `.gitignore`, `README.md`) — no RTL, sim, synth, backend, CI, or sw changes.

## What Changes

- Add a root-level `apm.mk`, included from the top-level `Makefile`, providing a `make apm` target that runs `apm install` (guarded by a `command -v apm` check that fails with an install hint, e.g. `brew install apm`, rather than installing the CLI itself).
- Add `.gitignore` entries for exactly the apm-managed `.claude/` paths (`.claude/agents/`, `.claude/rules/`, and the 7 apm-declared skill directories: `az-cost-optimize`, `azure-deployment-preflight`, `azure-pricing`, `azure-well-architected-review`, `docs-sync-audit`, `github-actions-efficiency`, `github-actions-hardening`) — leaving hand-authored `.claude/commands/`, `.claude/skills/openspec-*`, and `.claude/skills/systemverilog-style/` tracked as before.
- Keep `apm.yml` and `apm.lock.yaml` tracked in git (they are the lockfile / source of truth `make apm` reads, analogous to `package.json`/`package-lock.json`).
- Add a one-line "run `make apm` after cloning" note to `README.md`'s setup instructions.

## Capabilities

### New Capabilities
- `agent-tooling`: bootstrapping and version-controlling the apm-managed Claude Code assets (agents/rules/skills declared in `apm.yml`) via a `make apm` target, instead of committing the regenerated files.

### Modified Capabilities
(none — no existing capability covers local dev/agent tooling; see `openspec/specs/` for the current set, all EDA/CI-flow specific)

## Impact

- **New code**: `apm.mk` (new file); one new `include` line in the top-level `Makefile`.
- **Changed config**: `.gitignore` gains entries for the apm-managed `.claude/` paths.
- **Docs**: `README.md` gains a one-line setup step.
- **Other subsystems**: none affected — no `.github/workflows/*.yml` references `.claude/` or `apm` today, so CI behavior is unchanged either way.
- **Dependencies**: relies on the `apm` CLI already being installed locally (Homebrew formula, already in use); `make apm` does not attempt to install it.
- **Risk**: low. A contributor who forgets to run `make apm` simply won't have the Claude Code agents/skills locally — no build, test, or CI path depends on their presence.
