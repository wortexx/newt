# Spec Delta

## ADDED Requirements

### Requirement: Detailed routing reports the antenna checker's own counts

When detailed routing produces a routed design, the stage SHALL run the antenna checker on it and SHALL report:

- the number of nets that violate an antenna rule;
- the number of pins that violate an antenna rule;
- the checker's full report, as one of the run's reports.

These counts SHALL come from the checker's own output. The run's status SHALL carry them on their own row, under a name that says they are antenna counts. The check SHALL run whether or not antenna repair ran. If the checker fails or reports no counts, the run's status SHALL say so rather than show zero. Checking and reporting SHALL NOT change the routed design, the stage's outcome or the run's exit status.

#### Scenario: Routed run without antenna repair

- **WHEN** detailed routing completes with antenna repair skipped
- **THEN** the run's status gives the violating net and pin counts from the antenna checker, and the checker's report is among the run's reports

#### Scenario: Routed run with antenna repair

- **WHEN** detailed routing completes after antenna repair ran
- **THEN** the antenna counts are those of the routed design after repair, and the status shows which repair mode ran

#### Scenario: The checker produces no count

- **WHEN** the antenna checker fails or logs no count
- **THEN** the run's status says no antenna count was reported, and the stage's outcome and the run's exit status are unchanged

#### Scenario: Detailed routing produces no routed design

- **WHEN** detailed routing fails or times out before it saves a routed design
- **THEN** no antenna counts are reported for that run, and the run's status does not give an antenna count of zero

### Requirement: Global routing can hold back Metal5 over the SRAMs

The flow SHALL accept a share of Metal5's routing capacity that global routing holds back inside the footprint of every SRAM macro, in addition to the flow's per-layer adjustments. By default the share SHALL be zero, so global routing is the same as without this setting. A value outside 0 (inclusive) to 1 (exclusive) SHALL fail the stage that reads it, with an error naming the setting. When the share is non-zero, every stage that runs global or detailed routing SHALL apply it, and each such stage's log SHALL record the share and the number of SRAM regions it covered. The setting SHALL NOT change any other layer's adjustment, or Metal5's capacity outside the SRAM footprints.

#### Scenario: Default

- **WHEN** the flow runs without the Metal5 hold-back set
- **THEN** global routing applies no extra Metal5 adjustment over the SRAMs, and the layout matches a run made before this setting existed

#### Scenario: Hold-back set

- **WHEN** the flow runs with a Metal5 hold-back of 0.55
- **THEN** global routing holds back 55 % of Metal5's capacity inside every SRAM macro's footprint, and every routing stage's log records 0.55 and the number of SRAM regions covered

#### Scenario: Invalid value

- **WHEN** the Metal5 hold-back is set to a value that is not a number, is negative, or is 1 or more
- **THEN** the stage that reads it fails with an error naming the setting, before any routing runs
