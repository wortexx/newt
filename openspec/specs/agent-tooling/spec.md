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

### Requirement: Provide a root-level AGENTS.md for coding agents
The repository SHALL provide a root-level `AGENTS.md` file that gives a coding agent (Claude Code or any other tool that reads the AGENTS.md convention) what it needs to work in this repo safely: a project/thesis overview, tool setup (Docker vs. local), a command reference for the build/simulate/synthesize/backend flow (the `make ig-*` targets), the repo layout, the CI lanes, and the hard constraints an agent must not violate (naming that many scripts hardcode, dependency-forking-not-patching policy, and the cost/duration of the synth and backend stages). `AGENTS.md` SHALL NOT duplicate authoritative detail already maintained elsewhere (e.g. `infra/azure/README.md`, `docs/infra-plan.md`, `docs/pnr-pipeline.md`) — it SHALL summarize and link to those instead.

#### Scenario: Agent onboarding to the repo
- **WHEN** a coding agent starts working in this repo and reads `AGENTS.md` at the repo root
- **THEN** it finds the project overview, how to set up tools (Docker or local), the full `make ig-*` command reference grouped by flow stage (hw/pickle/synth/backend/sw/sim), the repo's top-level directory layout, and the CI lanes table

#### Scenario: Agent about to run an expensive or unsafe target
- **WHEN** a coding agent is deciding whether to run a build target such as `make synth-all` or `make backend-all`, or is tempted to rename the project or patch a vendored dependency in place
- **THEN** `AGENTS.md` states the expected cost/duration of the synth and backend stages, and states that `PROJ_NAME`/`RTL_NAME` must stay `basilisk` and that `cheshire`/`cva6` are modified via forks pinned in `Bender.yml`, not local patches

#### Scenario: Underlying docs change
- **WHEN** README.md's tool/build instructions, the CI lanes table, or a linked doc (`docs/infra-plan.md`, `docs/pnr-pipeline.md`, `infra/azure/README.md`) changes in a way that makes `AGENTS.md`'s summary inaccurate
- **THEN** `AGENTS.md` is updated in the same change so it does not drift from the sources it summarizes
