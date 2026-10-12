## ADDED Requirements

### Requirement: Detailed routing can traverse every net's route guides

Before detailed routing starts, the flow SHALL make every net's route guides traversable by detailed routing. Where a guide on a routing layer spans more than one gcell against that layer's preferred direction, the flow SHALL add a guide covering the same area on an adjacent routing layer whose preferred direction matches. Guides from global routing SHALL NOT be removed or shrunk. The flow SHALL report how many guides it added and on how many nets. The step SHALL be on by default and SHALL be possible to turn off by configuration, in which case detailed routing sees global routing's guides unchanged.

#### Scenario: A pin is reachable only through a wrong-direction guide

- **WHEN** global routing connects a pin to the rest of its net only through a guide that runs against its layer's preferred direction
- **THEN** detailed routing's guide processing completes for that net without `DRT-0218`, and routing proceeds to track assignment

#### Scenario: No wrong-direction guides

- **WHEN** no guide spans more than one gcell against its layer's preferred direction
- **THEN** the flow adds no guides, reports zero, and detailed routing sees global routing's guides unchanged

#### Scenario: Bridging turned off

- **WHEN** a run is configured with the bridging step off
- **THEN** no guides are added, the stage log says the step was skipped, and detailed routing sees global routing's guides unchanged
