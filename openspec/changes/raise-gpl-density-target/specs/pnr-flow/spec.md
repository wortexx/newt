## ADDED Requirements

### Requirement: Placement density target leaves headroom over the design's utilization

The flow's global-placement density target SHALL be above the utilization the design actually reaches entering detailed placement, which includes the cells added by placement-time repair. A run SHALL report the density target and the measured utilization side by side, and SHALL flag a run whose utilization is at or above the target. The flag is a named warning in the run's output, not a failure, so that a growing design is noticed before it shows up as a legalization timeout.

#### Scenario: Current design places within the target

- **WHEN** the P&R flow runs on the current Basilisk netlist
- **THEN** the utilization reported entering detailed placement is below the global-placement density target, and detailed placement and CTS complete within their configured stage timeouts

#### Scenario: Design with the SHA-3 coprocessor still fits

- **WHEN** the flow runs on the netlist with the SHA-3 coprocessor (about 0.84 mm² more cell area)
- **THEN** its utilization entering detailed placement is still below the density target

#### Scenario: Design outgrows the target

- **WHEN** a run's utilization entering detailed placement is at or above the density target
- **THEN** the run's output contains a warning naming both values, and the run's exit status is still decided only by the stage gates
