## Purpose

Defines what runs automatically on every push and pull request against this repository, which of those checks actually gate merges today, and how a currently-stubbed check is required to behave until the work that unblocks it lands.

## ADDED Requirements

### Requirement: CI runs on every push and pull request
The system SHALL run a CI workflow on every push to any branch and on every pull request, using the `newt-eda` container image on a GitHub-hosted runner.

#### Scenario: PR opened against main
- **WHEN** a pull request is opened or updated against `main`
- **THEN** the CI workflow runs and reports a status for each of its jobs on the PR

#### Scenario: Push to a non-main branch
- **WHEN** a commit is pushed to any branch
- **THEN** the CI workflow runs the same job set as it would for a PR

### Requirement: Lint job blocks on real findings
The system SHALL run a `lint` job that checks `bender sources` (dependency graph resolution), `verible-verilog-lint`, and `verilator --lint-only` against changed RTL, and SHALL fail the job (non-zero exit) if any of those report an error-level finding.

#### Scenario: Clean RTL change
- **WHEN** a PR's changed RTL passes `bender sources`, `verible-verilog-lint`, and `verilator --lint-only` with no errors
- **THEN** the `lint` job exits 0

#### Scenario: RTL change introduces a lint error
- **WHEN** a PR's changed RTL fails any of the three checks with an error-level finding
- **THEN** the `lint` job exits non-zero and the failing tool's output is visible in the job log

### Requirement: Software build job blocks on build failure
The system SHALL run an `sw` job that builds the existing test binaries with the riscv64 toolchain, and SHALL fail the job if the build does not complete successfully.

#### Scenario: sw/ builds cleanly
- **WHEN** `sw/tests/` builds successfully against the current RTL/config
- **THEN** the `sw` job exits 0

#### Scenario: sw/ fails to build
- **WHEN** a change breaks the riscv64 build of any existing test binary
- **THEN** the `sw` job exits non-zero and the compiler error is visible in the job log

### Requirement: Real jobs are required status checks
The system SHALL configure `main`'s branch protection so that the `lint` and `sw` job statuses are required to pass before a PR can merge.

#### Scenario: lint or sw fails on a PR targeting main
- **WHEN** the `lint` or `sw` job fails on a PR targeting `main`
- **THEN** the merge button is blocked by branch protection until the job passes

### Requirement: Stubbed jobs run, self-report their blocker, and never gate merges
For a check whose real implementation depends on work that has not landed yet (a coprocessor testbench, a coprocessor RTL module, or the Verilator green-light run), the system SHALL still run a job under that check's final name, SHALL make the job print which specific blocker it is waiting on, and SHALL make the job exit 0 regardless of the underlying condition it could not yet evaluate. Such a job SHALL NOT be added to `main`'s required status checks while stubbed.

#### Scenario: Coprocessor unit-test job runs before coprocessor RTL exists
- **WHEN** the `sim-unit` job runs on a PR and no coprocessor RTL/testbench exists in the tree
- **THEN** the job exits 0 and its output states that it is a stub pending Phase 7 coprocessor RTL

#### Scenario: SoC simulation job runs while the Verilator green light is blocked
- **WHEN** the `sim-soc` job runs on a PR and the Verilator green-light run (per `verilator-sim-flow`) does not yet pass
- **THEN** the job attempts the run, reports the known-blocked outcome by name, and exits 0 rather than failing the PR

#### Scenario: Coprocessor synthesis job runs before a coprocessor module exists
- **WHEN** the `synth-coproc` job runs on a PR and no coprocessor module exists to synthesize
- **THEN** the job exits 0 and its output states that it is a stub pending Phase 7 coprocessor RTL

#### Scenario: A stub job is never a required status check
- **WHEN** `main`'s branch protection required-status-checks list is inspected while `sim-unit`, `sim-soc`, or `synth-coproc` is still stubbed
- **THEN** none of those three job names appear in the required list

### Requirement: A stub job graduates to gating only via an explicit follow-up
Once the blocker a stub job names is resolved (coprocessor RTL exists and passes its own tests, or the Verilator green light passes), the system SHALL require that job to actually evaluate its real condition and fail on a real regression, and SHALL require it be added to `main`'s required status checks at that point — not automatically, but as a deliberate follow-up change.

#### Scenario: Verilator green light starts passing
- **WHEN** the `verilator-sim-flow` blocker is resolved and `make ig-sim-verilator` passes on the green-light test
- **THEN** a follow-up change updates `sim-soc` to fail on a real regression and adds it to the required-status-checks list
