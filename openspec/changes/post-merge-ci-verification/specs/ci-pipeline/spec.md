# ci-pipeline — post-merge-ci-verification

## MODIFIED Requirements

### Requirement: P&R lane runs weekly, on demand, and on tags — never per-PR

The system SHALL provide a P&R CI lane, in a workflow separate from the fast and synth lanes, that runs on: a weekly schedule against `main`, a manual `workflow_dispatch`, and pushed tags/releases. It SHALL NOT run on pushes or pull requests (labeled or otherwise), so no fork-sourced code can ever reach it via a PR event.

The manual dispatch SHALL accept three optional inputs, all empty by default: a previous run whose checkpoints to restore before the flow starts, a list of checkpoints to leave out of that restore so their stages run again, and a stage after which the run stops. With all three empty, a dispatched run SHALL behave exactly like a scheduled run. These inputs SHALL NOT change the flow's success gate: a run that stops before the gate stage is reached SHALL still exit non-zero.

#### Scenario: Weekly run

- **WHEN** the weekly scheduled trigger fires
- **THEN** the P&R lane runs once against the current `main`

#### Scenario: Tag push

- **WHEN** a tag is pushed
- **THEN** the P&R lane runs against that tag

#### Scenario: Ordinary PR or push

- **WHEN** a pull request is opened/labeled or a branch is pushed
- **THEN** the P&R lane does not run

#### Scenario: Manual dispatch with no inputs

- **WHEN** a user dispatches the P&R lane without naming a run to resume from, checkpoints to exclude, or a stage to stop after
- **THEN** the lane runs the full flow from synthesis through detailed route exactly as a scheduled run would

#### Scenario: Manual dispatch re-runs one slice of the flow

- **WHEN** a user dispatches the P&R lane naming a previous run to resume from, a checkpoint to exclude, and a stage to stop after
- **THEN** the lane restores that run's checkpoints (refusing if they were built from a different netlist than the dispatched ref produces), skips every stage whose checkpoint was restored, runs the excluded stage again, stops once the named stage completes, publishes reports and checkpoints as usual, and exits 0 if and only if every stage through the gate was completed or restored
