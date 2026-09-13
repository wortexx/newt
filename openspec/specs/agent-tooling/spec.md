# agent-tooling Specification

## Purpose

Governs how Claude Code agents, skills, and rules sourced from external `apm` packages (declared in `apm.yml`) are bootstrapped into a contributor's working tree and kept out of version control, so the repo carries a lockfile instead of regenerable third-party content.

## Requirements

### Requirement: Bootstrap apm-managed Claude Code assets via `make apm`
The repository SHALL provide a `make apm` target that runs `apm install` to (re)materialize every Claude Code agent, rule, and skill declared in `apm.yml` and pinned in `apm.lock.yaml`. The target SHALL fail with an actionable message when the `apm` CLI is not on `PATH`, rather than silently doing nothing or attempting to install the CLI itself.

#### Scenario: Fresh clone with the apm CLI installed
- **WHEN** a contributor clones the repo (no `.claude/agents/`, `.claude/rules/`, or apm-managed `.claude/skills/*` directories present) and the `apm` CLI is already on `PATH`
- **THEN** running `make apm` invokes `apm install` and populates those directories to match `apm.lock.yaml`

#### Scenario: apm CLI not installed
- **WHEN** a contributor runs `make apm` without the `apm` CLI on `PATH`
- **THEN** the target fails with a message telling them how to install `apm` (e.g. `brew install apm`), and does not attempt to install it automatically

#### Scenario: Re-running after assets already exist
- **WHEN** `make apm` is run again while the apm-managed `.claude/` directories already match `apm.lock.yaml`
- **THEN** `apm install` reports nothing to change and the target completes without modifying unrelated files

### Requirement: Exclude apm-managed Claude Code assets from version control
Apm-managed Claude Code assets — `.claude/agents/`, `.claude/rules/`, and the `.claude/skills/*` directories declared in `apm.yml`'s `dependencies.apm` list — SHALL be excluded from git via `.gitignore`, while hand-authored `.claude/` content (`.claude/commands/`, and any `.claude/skills/*` not declared in `apm.yml`) SHALL remain tracked. The `apm.yml` and `apm.lock.yaml` manifest/lockfile files themselves SHALL remain tracked.

#### Scenario: Apm-managed paths are ignored
- **WHEN** `apm install` writes files under `.claude/agents/`, `.claude/rules/`, or an apm-declared `.claude/skills/<name>/` directory
- **THEN** `git status` does not list those files as untracked or modified

#### Scenario: Hand-authored Claude Code assets stay tracked
- **WHEN** a contributor inspects `git status` or `git ls-files` after running `make apm`
- **THEN** `.claude/commands/` and any `.claude/skills/*` directory not declared in `apm.yml` (e.g. hand-authored project skills) continue to appear as tracked files, unaffected by the new `.gitignore` entries

#### Scenario: Lockfile stays tracked
- **WHEN** `apm.yml` or `apm.lock.yaml` changes (e.g. a dependency is added)
- **THEN** `git status` reports the change normally, since these files are not gitignored
