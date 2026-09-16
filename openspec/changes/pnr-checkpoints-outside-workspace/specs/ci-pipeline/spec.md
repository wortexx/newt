# ci-pipeline — pnr-checkpoints-outside-workspace

## MODIFIED Requirements

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
