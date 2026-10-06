## MODIFIED Requirements

### Requirement: Timing and power with a stated measurement stage

Every reported timing or power figure SHALL name the flow stage it was taken from: block synthesis, post-placement, post-CTS or post-global-route. It SHALL also name the operating corner. A figure taken at post-global-route SHALL also state whether post-route timing repair ran before it was taken, and if the repair was attempted but did not complete, why. An achieved clock period or frequency derived from a worst negative slack SHALL name the stage and the repair status of that slack, and SHALL NOT be presented as the SoC's maximum frequency when repair was skipped. Power for the coprocessor and the accelerator SHALL be computed from switching activity recorded while running a hashing workload on that block. Default activity assumptions SHALL NOT be used. Every energy-per-hash or energy-per-byte figure SHALL be derived from such activity-annotated power, combined with measured cycle counts and the stated clock frequency.

#### Scenario: Power figure carries its provenance

- **WHEN** a power or energy number appears in the report
- **THEN** the report states the flow stage, the corner, the workload that produced the activity, and that the activity was annotated rather than defaulted

#### Scenario: Unavailable stage is reported, not substituted silently

- **WHEN** the P&R lane cannot reach a stage that the report intended to quote from
- **THEN** the report names the stage that was actually used and the reason

#### Scenario: Global-route timing carries its repair status

- **WHEN** a WNS, TNS or achieved period taken at post-global-route appears in the report
- **THEN** the report states whether post-route timing repair ran, and the reference and coprocessor figures it compares were both taken with the same repair status

#### Scenario: Repair attempted but not completed

- **WHEN** post-route timing repair was attempted for a run and timed out or failed
- **THEN** the report quotes the post-global-route figure without repair, labels it as such, and names the repair attempt's outcome and its run
