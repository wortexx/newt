# Spec Delta

## MODIFIED Requirements

### Requirement: Global routing can hold back Metal5 over the SRAMs

The flow SHALL accept a share of Metal5's routing capacity that global routing holds back inside the footprint of every SRAM macro, in addition to the flow's per-layer adjustments. By default the share SHALL be 0.55. A share of zero SHALL leave global routing the same as without this setting. A value outside 0 (inclusive) to 1 (exclusive) SHALL fail the stage that reads it, with an error naming the setting. When the share is non-zero, every stage that runs global or detailed routing SHALL apply it, and each such stage's log SHALL record the share and the number of SRAM regions it covered. The setting SHALL NOT change any other layer's adjustment, or Metal5's capacity outside the SRAM footprints.

#### Scenario: Default

- **WHEN** the flow runs without the Metal5 hold-back set
- **THEN** global routing holds back 55 % of Metal5's capacity inside every SRAM macro's footprint, and every routing stage's log records 0.55 and the number of SRAM regions covered

#### Scenario: Hold-back set to zero

- **WHEN** the flow runs with a Metal5 hold-back of 0
- **THEN** global routing applies no extra Metal5 adjustment over the SRAMs, and the layout matches a run made before this setting existed

#### Scenario: Hold-back set

- **WHEN** the flow runs with a Metal5 hold-back of 0.70
- **THEN** global routing holds back 70 % of Metal5's capacity inside every SRAM macro's footprint, and every routing stage's log records 0.70 and the number of SRAM regions covered

#### Scenario: Invalid value

- **WHEN** the Metal5 hold-back is set to a value that is not a number, is negative, or is 1 or more
- **THEN** the stage that reads it fails with an error naming the setting, before any routing runs
