# ci-pipeline delta — ci-pnr-lane

## ADDED Requirements

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

#### Scenario: Nightly synth fires during a P&R run

- **WHEN** the synth lane's schedule fires while the P&R job occupies the runner
- **THEN** the synth job queues and runs after the P&R job, and the P&R stop step leaves the VM up for it

#### Scenario: Runner is free at stop time

- **WHEN** the P&R job ends and no other job is running or queued on the runner
- **THEN** the stop step deallocates the VM

### Requirement: P&R lane publishes routing outputs and preserves checkpoints

The lane SHALL upload the routed design (DEF) and the flow's reports and logs as workflow artifacts with bounded retention — reports and logs even when the run fails — and SHALL upload the flow's stage checkpoints to Azure Blob storage governed by a ~30-day lifecycle expiry, so a failed or stopped run can be resumed or diagnosed without re-running days of flow.

#### Scenario: Successful run publishes outputs

- **WHEN** a P&R run exits 0
- **THEN** the DEF and reports are downloadable as workflow artifacts and the run's checkpoints exist in Blob storage

#### Scenario: Failed run still publishes diagnostics

- **WHEN** a P&R run fails partway
- **THEN** the reports/logs produced so far are uploaded as artifacts and the checkpoints saved before the failure exist in Blob storage

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
