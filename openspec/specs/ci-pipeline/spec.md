# ci-pipeline Specification

## Purpose

Defines what runs automatically on every push and pull request against this repository, on a separate scheduled/on-demand full-synthesis lane, and on a weekly/on-demand place-and-route lane that owns its own self-hosted VM's lifecycle; which of those checks actually gate merges today; and how a currently-stubbed check is required to behave until the work that unblocks it lands.

## Requirements

### Requirement: CI runs on every push to main and every pull request

The system SHALL run a CI workflow on every push to `main` and on every pull request (which GitHub re-triggers on every subsequent push to that PR's branch), using the `newt-eda` container image on a GitHub-hosted runner. A push to a branch with no open pull request SHALL NOT trigger the workflow, so that a push to a branch already covered by an open PR does not also trigger a redundant, duplicate run of the same commit.

#### Scenario: PR opened against main

- **WHEN** a pull request is opened or updated against `main`
- **THEN** the CI workflow runs and reports a status for each of its jobs on the PR

#### Scenario: Further pushes to an open PR's branch

- **WHEN** a commit is pushed to a branch that already has an open pull request
- **THEN** the CI workflow runs once (via the `pull_request` trigger) for that commit, not twice

#### Scenario: Push directly to main

- **WHEN** a commit is pushed directly to `main` (e.g. a merge)
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

### Requirement: Synth lane runs on a schedule and on demand, not per-PR

The system SHALL provide a full-synthesis CI lane, in a workflow separate from the per-PR fast lane, that runs on: a nightly schedule against `main`, a manual `workflow_dispatch`, and pull requests carrying the `full-synth` label (including re-runs on subsequent pushes to a PR while the label is present). It SHALL NOT run on unlabeled pushes or pull requests.

#### Scenario: Nightly run

- **WHEN** the scheduled trigger fires
- **THEN** the synth lane runs once against the current `main`

#### Scenario: Manual dispatch

- **WHEN** a user triggers the workflow via `workflow_dispatch`
- **THEN** the synth lane runs against the selected ref

#### Scenario: PR labeled full-synth

- **WHEN** the `full-synth` label is added to an open pull request, or a commit is pushed to a PR that already carries the label
- **THEN** the synth lane runs against that PR's head and reports its status on the PR

#### Scenario: Ordinary PR without the label

- **WHEN** a pull request without the `full-synth` label is opened or updated
- **THEN** the synth lane does not run for it

### Requirement: Synth lane never auto-executes a fork pull request's code

Because the synth lane runs on a self-hosted runner, the system SHALL NOT automatically run the synth lane against a pull request whose head branch is not part of the `wortexx/newt` repository itself, even when that pull request carries the `full-synth` label. Such a run SHALL require explicit maintainer approval before it executes.

#### Scenario: Same-repo branch carries the label

- **WHEN** a pull request from a branch of `wortexx/newt` itself carries the `full-synth` label
- **THEN** the synth lane runs automatically, per the labeled-PR requirement above

#### Scenario: Fork pull request carries the label

- **WHEN** a pull request from a fork carries the `full-synth` label
- **THEN** the synth lane does not run automatically against it; it runs only after a maintainer explicitly approves that run

### Requirement: Synth lane runs the full pickle-to-netlist flow

The synth lane SHALL run the complete hardware-generation, pickling, and monolithic yosys synthesis flow (`ig-hw-all`, then `pickle-all`, then `synth-all`) inside the `newt-eda` container, regenerating all flow inputs (including the bender sources manifest) in-container from a fresh checkout. It SHALL use the monolithic synthesis path, not the hierarchical one (known broken on this design).

#### Scenario: Flow runs end to end

- **WHEN** the synth lane runs on a revision where the flow is healthy
- **THEN** pickling and synthesis complete and a technology-mapped netlist is produced

#### Scenario: Pickle is never stale

- **WHEN** the synth lane runs on a revision that changed RTL since the last run
- **THEN** the synthesized netlist reflects that revision's RTL (pickling ran in the same job; no checkpoint or manifest from an earlier run or the developer's host is reused)

### Requirement: Synth lane publishes netlist and reports as artifacts

The synth lane SHALL upload the synthesized netlist and the synthesis report directory as workflow artifacts with a bounded retention period, so a run's outputs can be inspected and compared without re-running the ~3 h flow.

#### Scenario: Successful run uploads outputs

- **WHEN** a synth-lane run completes synthesis
- **THEN** the netlist and the report files are downloadable as artifacts of that run

#### Scenario: Failed run still uploads what exists

- **WHEN** a synth-lane run fails after producing logs or partial reports
- **THEN** whatever reports and logs exist are still uploaded to aid diagnosis

### Requirement: Synth lane posts a metrics summary compared against a checked-in baseline

The synth lane SHALL extract cell count, chip area, and DFF count from the synthesis reports, and WNS from a static-timing run of the produced netlist, and SHALL post them in the run's summary alongside each metric's delta versus a baseline file checked into the repository. The baseline SHALL only change via a deliberate commit (seeded from the Phase 1 adoption-gate reference run), never automatically from a CI run.

#### Scenario: Summary on a successful run

- **WHEN** a synth-lane run completes synthesis and timing analysis
- **THEN** the run summary shows cell count, chip area, DFF count, and WNS, each with its absolute value and delta vs the checked-in baseline

#### Scenario: Baseline is stable across runs

- **WHEN** two synth-lane runs execute against the same revision
- **THEN** both compare against the same checked-in baseline values; neither run rewrites the baseline

### Requirement: Synth lane fails only on flow failure or design-check problems, and never gates merges

The synth lane SHALL exit non-zero when any flow stage fails or when the yosys `CHECK` report contains one or more problems. It SHALL NOT fail because a metric drifted from the baseline (drift is reported in the summary only), and its job SHALL NOT be added to `main`'s required status checks.

#### Scenario: Yosys CHECK reports a problem

- **WHEN** synthesis completes but the `CHECK` report contains at least one problem
- **THEN** the synth-lane job exits non-zero

#### Scenario: Metrics drift but flow is clean

- **WHEN** synthesis completes with 0 `CHECK` problems and a metric differs from the baseline
- **THEN** the job exits 0 and the summary shows the drift

#### Scenario: Synth lane is not a required check

- **WHEN** `main`'s branch protection required-status-checks list is inspected
- **THEN** the synth-lane job name does not appear in it

### Requirement: P&R lane runs weekly, on demand, and on tags — never per-PR

The system SHALL provide a P&R CI lane, in a workflow separate from the fast and synth lanes, that runs on: a weekly schedule against `main`, a manual `workflow_dispatch`, and pushed tags/releases. It SHALL NOT run on pushes or pull requests (labeled or otherwise), so no fork-sourced code can ever reach it via a PR event.

#### Scenario: Weekly run

- **WHEN** the weekly scheduled trigger fires
- **THEN** the P&R lane runs once against the current `main`

#### Scenario: Tag push

- **WHEN** a tag is pushed
- **THEN** the P&R lane runs against that tag

#### Scenario: Ordinary PR or push

- **WHEN** a pull request is opened/labeled or a branch is pushed
- **THEN** the P&R lane does not run

### Requirement: P&R lane starts the VM before the job and deallocates it after

The lane SHALL start the self-hosted runner VM from a GitHub-hosted job before the P&R job runs, and SHALL deallocate the VM from a GitHub-hosted job after the P&R job ends, including when the P&R job fails, times out, or is cancelled — except when deallocating would interrupt or starve another workflow's job on the same runner (see the coexistence requirement). Deallocation failure SHALL be loudly visible in the run's outcome, not silently ignored.

#### Scenario: Normal run lifecycle

- **WHEN** a P&R lane run completes (success or failure)
- **THEN** the VM is deallocated by the lane's own stop step without human action

#### Scenario: Stop step cannot deallocate

- **WHEN** the deallocate call fails
- **THEN** the workflow run is marked failed (or otherwise visibly flags the VM as still running) so the cost leak is noticed

### Requirement: GitHub-to-Azure authentication uses OIDC with no long-lived stored secrets

The lane's Azure operations (VM start/deallocate, checkpoint upload) SHALL authenticate via GitHub's OIDC federation to an Azure identity scoped to only the resources this lane needs. No Azure client secret, certificate, or other long-lived credential SHALL be stored in the repository or its GitHub secrets.

#### Scenario: Workflow authenticates

- **WHEN** the start, stop, or upload step needs Azure access
- **THEN** it obtains a short-lived token via OIDC federation and the repo's secret store contains no Azure credential material

#### Scenario: Identity scope is bounded

- **WHEN** the federated identity's role assignments are inspected
- **THEN** they cover only the lane's VM operations and its checkpoint storage, not subscription-wide privileges

### Requirement: Fixed-time auto-shutdown must not kill in-flight lane runs

Once the lane's start/stop automation is active, the system SHALL NOT rely on a fixed wall-clock auto-shutdown that deallocates the VM regardless of running jobs (the mechanism that previously cancelled a synth run mid-flight). Any remaining cost backstop SHALL only deallocate a VM that has no CI job running on it.

#### Scenario: Multi-day P&R run crosses the old shutdown hour

- **WHEN** a P&R run is in progress at a time of day when the old fixed auto-shutdown would have fired
- **THEN** the run continues uninterrupted

#### Scenario: VM idle with no jobs

- **WHEN** the VM is running with no CI job active or queued against its runner
- **THEN** the cost backstop deallocates it (or the stop automation already has)

### Requirement: P&R lane coexists with the synth lane on the shared runner

Because the P&R and synth lanes share one runner VM, the system SHALL serialize their jobs rather than fail on contention, and the P&R lane's deallocate step SHALL NOT power off the VM while a synth-lane job is running or queued on that runner. A synth-lane run delayed behind a multi-day P&R run is accepted behavior, not an error.

Because the two lanes also share that runner's single checkout workspace, and any job's checkout is free to clean every untracked file in it, the P&R lane SHALL NOT keep any output that a later job of the same run still needs — in particular its stage checkpoints and their netlist-identity marker — only in the shared workspace while the runner is free for another job. Another lane's job running on the runner between the P&R job and the checkpoint upload SHALL NOT cause any checkpoint to be lost.

#### Scenario: Nightly synth fires during a P&R run

- **WHEN** the synth lane's schedule fires while the P&R job occupies the runner
- **THEN** the synth job queues and runs after the P&R job, and the P&R stop step leaves the VM up for it

#### Scenario: Runner is free at stop time

- **WHEN** the P&R job ends and no other job is running or queued on the runner
- **THEN** the stop step deallocates the VM

#### Scenario: Synth job takes the runner between the P&R job and the checkpoint upload

- **WHEN** the P&R job has finished and a queued synth-lane job is assigned the runner — and cleans the shared workspace — before the P&R run's checkpoint upload job starts
- **THEN** the checkpoint upload still finds every checkpoint the P&R job saved, uploads them to Blob storage under the P&R run's ID, and the synth job's own outcome is unaffected

### Requirement: P&R lane publishes routing outputs and preserves checkpoints

The lane SHALL upload the flow's reports and logs as workflow artifacts with bounded retention — even when the run fails — SHALL upload the routed design (DEF) whenever detailed routing produces one, and SHALL upload the flow's stage checkpoints to Azure Blob storage governed by a ~30-day lifecycle expiry, so a failed or stopped run can be resumed or diagnosed without re-running days of flow.

A DEF is published conditionally rather than on every successful run because detailed routing is best-effort by design (see `pnr-flow`: success is gated through global route). A run can therefore legitimately exit 0 without a routed design — on a congestion-bound design that is an expected measurement result, not a lane failure — and the absence of a DEF SHALL be reported rather than silently producing an empty artifact or failing the run.

The checkpoint upload SHALL distinguish "nothing was saved" from "what was saved is gone": when the P&R job completed successfully but no checkpoint is available to upload, the upload job SHALL fail with a visible error rather than report nothing to do and succeed. When the P&R job did not complete (failed, cancelled, or timed out) the upload job SHALL upload whatever checkpoints exist and SHALL state, in its log, why there may be none.

#### Scenario: Successful run publishes outputs

- **WHEN** a P&R run exits 0 and detailed routing produced a routed design
- **THEN** the DEF and reports are downloadable as workflow artifacts and the run's checkpoints exist in Blob storage

#### Scenario: Run exits 0 without a routed design

- **WHEN** a P&R run exits 0 because global route completed, but detailed routing did not produce a routed design
- **THEN** the reports and checkpoints are still published, the run's summary states that no DEF was produced and which stage prevented it, and the run is not marked failed

#### Scenario: Failed run still publishes diagnostics

- **WHEN** a P&R run fails partway
- **THEN** the reports/logs produced so far are uploaded as artifacts and the checkpoints saved before the failure exist in Blob storage

#### Scenario: Successful flow but no checkpoints to upload

- **WHEN** the P&R job completed successfully and the checkpoint upload finds no checkpoint to upload
- **THEN** the upload job fails with an error naming where it looked, so the missing checkpoints are noticed in the run's outcome instead of being discovered at the next resume attempt

#### Scenario: Old checkpoints expire

- **WHEN** a checkpoint object is older than the lifecycle rule's threshold
- **THEN** Azure removes it without manual intervention

### Requirement: P&R lane job status follows the flow's gate and never gates merges

The P&R job SHALL exit non-zero exactly when the flow does (a stage up to and including global route failed, per `pnr-flow`), SHALL NOT fail on detailed-route non-convergence or timing non-closure, and SHALL NOT be added to `main`'s required status checks.

#### Scenario: Detailed route stops at its budget

- **WHEN** the flow exits 0 with detailed routing unconverged
- **THEN** the P&R job succeeds and its summary reports the routing outcome

#### Scenario: Not a required check

- **WHEN** `main`'s branch protection required-status-checks list is inspected
- **THEN** no P&R lane job name appears in it

### Requirement: Infrastructure templates are validated on every pull request that touches them

The system SHALL run, on a GitHub-hosted runner, a check that compiles and lints the infrastructure templates on every pull request (and every push to `main`) that changes files under the infrastructure directory. The check SHALL fail on any compile error or lint error. It SHALL NOT authenticate to Azure, SHALL NOT preview or apply deployments, and SHALL NOT require any secret or environment — validation is purely local to the checkout, so the CI identity's scope is never widened for it.

#### Scenario: Template error on a PR

- **WHEN** a pull request changes an infrastructure template so it no longer compiles or fails a lint rule
- **THEN** the check fails and the error is visible in the job log

#### Scenario: Clean template change

- **WHEN** a pull request changes infrastructure templates that compile and lint cleanly
- **THEN** the check exits 0

#### Scenario: PR does not touch infrastructure

- **WHEN** a pull request changes no file under the infrastructure directory
- **THEN** the infrastructure validation check does not run

#### Scenario: No Azure access

- **WHEN** the validation job's configuration is inspected
- **THEN** it declares no Azure login step, no environment, and no OIDC token permission
