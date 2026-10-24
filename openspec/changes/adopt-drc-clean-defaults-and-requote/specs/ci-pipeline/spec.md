# Spec Delta

## MODIFIED Requirements

### Requirement: P&R lane runs weekly, on demand, and on tags — never per-PR

The system SHALL provide a P&R CI lane, in a workflow separate from the fast and synth lanes, that runs on: a weekly schedule against `main`, a manual `workflow_dispatch`, and pushed tags/releases. It SHALL NOT run on pushes or pull requests (labeled or otherwise), so no fork-sourced code can ever reach it via a PR event.

The manual dispatch SHALL accept these optional inputs, all empty by default:

- a previous run whose checkpoints to restore before the flow starts;
- a list of checkpoints to leave out of that restore, so their stages run again;
- a stage after which the run stops;
- the global-placement starting density, the global-placement resize threshold, and the die scale;
- the legalizer used by detailed placement and CTS, and its search window;
- whether to skip post-route timing repair.
- detailed routing's iteration budget;
- which antenna repair runs before detailed routing: jumper insertion only, full repair, or none;
- the share of Metal2's capacity that global routing holds back;
- the share of Metal5's capacity that global routing holds back over the SRAMs;
- the placement padding, in sites, on each side of every standard cell.

An empty input SHALL keep the flow's default for that setting. Post-route timing repair SHALL be skipped by default and SHALL run only when the dispatch explicitly asks for it. Antenna repair SHALL run in jumper-only mode by default. Full repair SHALL run only when the dispatch explicitly asks for it, and the dispatch SHALL be able to skip antenna repair. An antenna-repair value that names no known mode SHALL fail the run before P&R starts, rather than fall back to a default. An empty iteration budget SHALL keep the lane's default budget. An empty Metal2 hold-back SHALL keep the flow's default. An empty SRAM Metal5 hold-back SHALL keep the flow's default. An empty cell padding SHALL keep the flow's default of no padding. With all inputs empty, a dispatched run SHALL behave exactly like a scheduled run. These inputs SHALL NOT change the flow's success gate: a run that stops before the gate stage is reached SHALL still exit non-zero, and post-route repair, antenna repair and detailed routing SHALL stay best-effort whether they are skipped, complete, fail or time out. Selecting a legalizer SHALL NOT bypass the flow's placement legality checks.

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
- **THEN** the lane runs the full flow from synthesis through detailed route exactly as a scheduled run would, with the default legalizer, with post-route timing repair skipped, and with jumper-only antenna repair before detailed routing

#### Scenario: Manual dispatch re-runs one slice of the flow

- **WHEN** a user dispatches the P&R lane naming a previous run to resume from, a checkpoint to exclude, and a stage to stop after
- **THEN** the lane restores that run's checkpoints (refusing if they were built from a different netlist than the dispatched ref produces), skips every stage whose checkpoint was restored, runs the excluded stage again, stops once the named stage completes, publishes reports and checkpoints as usual, and exits 0 if and only if every stage through the gate was completed or restored

#### Scenario: Manual dispatch selects the legalizer

- **WHEN** a user dispatches the P&R lane naming the non-default legalizer
- **THEN** detailed placement and CTS legalize with it, the placement report names it, and an illegal placement still fails the stage it occurs in

#### Scenario: Manual dispatch widens the legalizer's search window

- **WHEN** a user dispatches the P&R lane with a legalizer search window
- **THEN** every legalization uses that window, the stage logs record the window used, and an illegal placement still fails the stage it occurs in

#### Scenario: Manual dispatch runs post-route repair

- **WHEN** a user dispatches the P&R lane asking for post-route timing repair not to be skipped
- **THEN** the post-route repair stage runs its bounded repair instead of re-saving the global-route checkpoint, its reports are published like any other stage's, and its failure or timeout is recorded in the run's status without changing the run's exit status

#### Scenario: Manual dispatch sets the detailed-routing budget

- **WHEN** a user dispatches the P&R lane with a detailed-routing iteration budget
- **THEN** detailed routing stops after at most that many iterations, the stage's status records the budget used, and the run's exit status still follows the global-route gate

#### Scenario: Manual dispatch runs antenna repair

- **WHEN** a user dispatches the P&R lane asking for full antenna repair
- **THEN** the detailed-route stage runs antenna repair, inserting jumpers and diodes, before routing, its status records that full repair ran, and a failure or timeout in it does not change the run's exit status

#### Scenario: Manual dispatch runs jumper-only antenna repair

- **WHEN** a user dispatches the P&R lane asking for jumper-only antenna repair
- **THEN** the detailed-route stage runs antenna repair before routing without inserting diode cells, its status records that jumper-only repair ran, and a failure or timeout in it does not change the run's exit status

#### Scenario: Manual dispatch skips antenna repair

- **WHEN** a user dispatches the P&R lane asking for no antenna repair
- **THEN** the detailed-route stage routes without running antenna repair, and its status records that repair was skipped

#### Scenario: Manual dispatch names an unknown antenna-repair mode

- **WHEN** a user dispatches the P&R lane with an antenna-repair value that is neither empty nor a known mode
- **THEN** the run fails before P&R starts, with an error listing the accepted values

#### Scenario: Manual dispatch sets global routing's Metal2 hold-back

- **WHEN** a user dispatches the P&R lane with a Metal2 hold-back for global routing
- **THEN** global routing and every later routing stage hold back that share of Metal2's capacity, the stage logs record the value used, Metal3 keeps the flow's default, and the run's exit status still follows the global-route gate

#### Scenario: Manual dispatch sets the SRAM Metal5 hold-back

- **WHEN** a user dispatches the P&R lane with an SRAM Metal5 hold-back
- **THEN** global routing and every later routing stage hold back that share of Metal5's capacity inside every SRAM's footprint, the stage logs record the value used, no other layer's adjustment changes, and the run's exit status still follows the global-route gate

#### Scenario: Manual dispatch pads standard cells

- **WHEN** a user dispatches the P&R lane with a cell padding of N sites
- **THEN** global placement and every legalization keep N free sites on each side of every standard cell, the stage logs record N, the gated legality checks after `dpl` and `cts` fail the stage on any padding violation, filler placement is not padded, and the run's exit status still follows the global-route gate
