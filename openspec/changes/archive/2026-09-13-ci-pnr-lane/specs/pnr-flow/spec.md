# pnr-flow delta — ci-pnr-lane

## Purpose

Defines what the OpenROAD place-and-route flow must do when run unattended: complete without human intervention on the project's pinned OpenROAD version, survive its known failure modes, checkpoint its progress, and report how far routing got — on a design that is known not to close timing or converge detailed routing.

## ADDED Requirements

### Requirement: P&R flow completes unattended on the pinned OpenROAD version

The system SHALL provide a P&R flow entry point that runs the OpenROAD backend (floorplan through routing) headlessly, with no interactive input, GUI, or manual intervention, against the OpenROAD version shipped in the `newt-eda` image. A flow stage that is incompatible with that version's command API SHALL be adapted or replaced, not left to error out mid-run.

#### Scenario: Full unattended run

- **WHEN** the P&R flow is invoked headlessly in the `newt-eda` container on the synthesized Basilisk netlist
- **THEN** it proceeds from floorplan through its final stage and exits with a status code, without ever waiting on input or opening a GUI

#### Scenario: No unbounded repair loops

- **WHEN** the flow reaches a timing-repair step on a design that cannot close timing (WNS ≈ −2.5 ns)
- **THEN** the step completes within its configured bounds (or is skipped by configuration) rather than iterating indefinitely

### Requirement: Known-flaky steps are retried, not fatal on first failure

For a step with a known intermittent failure mode (`remove_buffers` segfaults on roughly one run in three), the system SHALL retry the step at least once from the most recent checkpoint before declaring the run failed.

#### Scenario: remove_buffers crashes once

- **WHEN** `remove_buffers` crashes on its first attempt
- **THEN** the flow retries it from the preceding checkpoint and continues if the retry succeeds

#### Scenario: remove_buffers crashes repeatedly

- **WHEN** `remove_buffers` crashes on the retry as well
- **THEN** the flow exits non-zero, and the checkpoint preceding the failed step is preserved for offline diagnosis

### Requirement: Flow checkpoints each major stage and can resume from a checkpoint

The system SHALL save a named checkpoint after each major stage (floorplan, power grid, placement, CTS, global route, detailed route), and SHALL support starting a run from a chosen checkpoint instead of from the beginning. A resumed run SHALL produce the same downstream behavior as an uninterrupted run — in particular, routing-layer configuration lost across a checkpoint reload SHALL be re-applied before routing continues.

#### Scenario: Resume after interruption

- **WHEN** a run is interrupted after CTS and a new run is started from the CTS checkpoint
- **THEN** the flow continues from CTS without re-running earlier stages

#### Scenario: Resumed run routes on the correct layers

- **WHEN** a run resumes from a post-CTS checkpoint and proceeds to routing
- **THEN** routing respects the same signal-layer restrictions as an uninterrupted run (no guides on excluded top layers, no `DRT-0155`-class failures caused by the reload)

### Requirement: Success is gated through global route; detailed route is best-effort

The flow SHALL exit 0 when floorplan, placement, CTS, and global routing all complete, regardless of detailed-routing convergence. Detailed routing SHALL run with a bounded iteration budget, and its outcome (converged, or stopped at the budget with a DRC-violation count trajectory) SHALL be reported without affecting the exit code. A failure in any stage up to and including global route SHALL exit non-zero.

#### Scenario: Global route completes, detailed route does not converge

- **WHEN** global routing completes cleanly and detailed routing stops at its iteration budget with violations remaining
- **THEN** the flow exits 0 and the report states the iteration count and the DRC-violation trajectory

#### Scenario: A gated stage fails

- **WHEN** placement, CTS, or global routing fails
- **THEN** the flow exits non-zero and identifies the failed stage in its output

### Requirement: Flow emits end-of-run reports

The system SHALL produce, at the end of a run (successful or not), the reports that exist at that point — at minimum utilization/area, timing (setup/hold summary), and routing status — in files a CI job or a human can collect without re-running the flow.

#### Scenario: Reports after a gated-success run

- **WHEN** a run exits 0
- **THEN** area, timing, and routing reports for the completed stages exist as files under the flow's report directory

#### Scenario: Reports after a failed run

- **WHEN** a run exits non-zero partway through
- **THEN** the reports and logs produced up to the failure point still exist on disk
