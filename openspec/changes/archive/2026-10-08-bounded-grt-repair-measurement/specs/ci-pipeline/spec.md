## MODIFIED Requirements

### Requirement: P&R lane runs weekly, on demand, and on tags — never per-PR

The system SHALL provide a P&R CI lane, in a workflow separate from the fast and synth lanes, that runs on: a weekly schedule against `main`, a manual `workflow_dispatch`, and pushed tags/releases. It SHALL NOT run on pushes or pull requests (labeled or otherwise), so no fork-sourced code can ever reach it via a PR event.

The manual dispatch SHALL accept these optional inputs, all empty by default:

- a previous run whose checkpoints to restore before the flow starts;
- a list of checkpoints to leave out of that restore, so their stages run again;
- a stage after which the run stops;
- the global-placement starting density, the global-placement resize threshold, and the die scale;
- whether to skip post-route timing repair.

An empty input SHALL keep the flow's default for that setting. Post-route timing repair SHALL be skipped by default and SHALL run only when the dispatch explicitly asks for it. With all inputs empty, a dispatched run SHALL behave exactly like a scheduled run. These inputs SHALL NOT change the flow's success gate: a run that stops before the gate stage is reached SHALL still exit non-zero, and post-route repair SHALL stay best-effort whether it is skipped, completes, fails or times out.

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

- **WHEN** a user dispatches the P&R lane without setting any input
- **THEN** the lane runs the full flow from synthesis through detailed route exactly as a scheduled run would, with post-route timing repair skipped

#### Scenario: Manual dispatch re-runs one slice of the flow

- **WHEN** a user dispatches the P&R lane naming a previous run to resume from, a checkpoint to exclude, and a stage to stop after
- **THEN** the lane restores that run's checkpoints (refusing if they were built from a different netlist than the dispatched ref produces), skips every stage whose checkpoint was restored, runs the excluded stage again, stops once the named stage completes, publishes reports and checkpoints as usual, and exits 0 if and only if every stage through the gate was completed or restored

#### Scenario: Manual dispatch runs post-route repair

- **WHEN** a user dispatches the P&R lane asking for post-route timing repair not to be skipped
- **THEN** the post-route repair stage runs its bounded repair instead of re-saving the global-route checkpoint, its reports are published like any other stage's, and its failure or timeout is recorded in the run's status without changing the run's exit status
