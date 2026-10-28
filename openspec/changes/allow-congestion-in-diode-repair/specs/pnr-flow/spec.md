# Spec Delta

## MODIFIED Requirements

### Requirement: Antenna repair is bounded and never costs the routed design

When antenna repair runs, it SHALL run as its own flow stage, after global routing and before detailed routing, in its own process with its own timeout. The stage SHALL keep two results:

- the design after jumper insertion;
- the design after diode insertion, when diode insertion is requested and completes.

Detailed routing SHALL route the newest result that exists. If diode insertion fails or times out, detailed routing SHALL route the jumper-repaired design, and the run's status SHALL record that the diode step failed and that the jumper result was routed. A failure or timeout in the antenna stage SHALL NOT prevent detailed routing from running, and SHALL NOT change the run's exit status. When diode insertion re-legalizes the placement, it SHALL use the legalizer the flow selects for every other legalization, and the stage log SHALL name it. When diode insertion reroutes the nets it changed, the reroute SHALL accept the congestion the global route already has, as the flow's global routing does, and SHALL NOT try to clear overflow it did not cause. The stage log SHALL state that congestion is allowed, and the run's status SHALL state how long the diode step took when it completes.

#### Scenario: Full repair completes

- **WHEN** the flow runs with full antenna repair and diode insertion completes within the stage's timeout
- **THEN** detailed routing routes the diode-repaired design, and the status records that full repair ran, with the number of jumpers and diodes inserted

#### Scenario: Diode insertion times out

- **WHEN** the flow runs with full antenna repair and diode insertion does not finish within the stage's timeout
- **THEN** detailed routing still runs, on the jumper-repaired design, and the status records the timeout and that the jumper result was routed

#### Scenario: Jumper-only repair

- **WHEN** the flow runs with jumper-only antenna repair
- **THEN** no diode is inserted, the stage's result is the jumper-repaired design, and detailed routing routes it

#### Scenario: Antenna repair skipped

- **WHEN** the flow runs with antenna repair skipped
- **THEN** detailed routing routes the global-route result unchanged, and the status records that repair was skipped

#### Scenario: Diode legalization uses the flow's legalizer

- **WHEN** diode insertion re-legalizes the placement
- **THEN** it uses the same legalizer as the flow's other legalizations, and the stage log names that legalizer

#### Scenario: Diode reroute on a congested global route

- **WHEN** the flow runs with full antenna repair on a global route that already has overflow
- **THEN** the reroute after diode insertion reroutes only the nets the diode step changed, leaves the existing overflow in place without failing on it, the stage log states that congestion is allowed, and the status gives the diode step's duration
