## ADDED Requirements

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
