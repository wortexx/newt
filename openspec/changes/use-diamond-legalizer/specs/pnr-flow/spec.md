## ADDED Requirements

### Requirement: Placement is legal before routing

Every legalization in the flow SHALL either place every cell legally or fail the stage it runs in. After detailed placement, and again at the end of CTS, the flow SHALL check placement legality: no overlapping cells, no padding violations, and no cells on blocked layers. A failed check SHALL fail that stage, which is gated, so the run exits non-zero there and never reaches routing with an illegal placement. The flow SHALL use, by default, a legalizer that never hands on a partly legalized placement. Another legalizer MAY be selected by configuration, and the legality check SHALL apply whichever legalizer runs.

#### Scenario: Placement legalizes

- **WHEN** detailed placement and CTS complete and both legality checks find no violations
- **THEN** both stages succeed, and routing starts from a placement in which every cell sits on a legal site

#### Scenario: Legalizer leaves cells illegal

- **WHEN** a legalization ends with overlapping cells, padding violations or cells on blocked layers
- **THEN** the legality check after that stage fails, the stage is reported as failed with the violation counts, its report file is kept, and the run exits non-zero without starting global routing

#### Scenario: Legalizer selected by configuration

- **WHEN** a run is configured to use the non-default legalizer
- **THEN** every legalization in the flow uses it, and the same legality checks decide whether detailed placement and CTS succeed

## MODIFIED Requirements

### Requirement: The run reports how global placement ended

After detailed placement, a run SHALL report:

- whether global placement's final pass converged or reverted after a divergence, and at what overflow;
- the final placement-area inflation;
- the utilization entering detailed placement;
- which legalizer ran;
- whether the placement legality check passed, with the violation counts when it did not;
- the number of illegal cells the legalizer starts from, when the legalizer logs one.

A final-pass revert SHALL be a named warning in the run's output, not a failure, so that an unconverged placement is noticed before it shows up as a legalization timeout or a legality failure. The report SHALL be produced whether or not detailed placement succeeded, from what detailed placement logs.

#### Scenario: Placement converges

- **WHEN** the P&R flow runs on the current Basilisk netlist with the default placement settings
- **THEN** the report shows the final global-placement pass ending without a revert, names the legalizer, and shows the legality check result, and detailed placement and CTS complete within their configured stage timeouts

#### Scenario: Placement reverts after a divergence

- **WHEN** global placement's final pass reverts to a snapshot after a divergence
- **THEN** the run's output contains a warning naming the overflow it reverted to, and the illegal cells detailed placement starts from when the legalizer logs them, and the run's exit status is still decided only by the stage gates

#### Scenario: Detailed placement times out

- **WHEN** detailed placement exceeds its stage timeout
- **THEN** the report is still printed, with the utilization, the legalizer, and any illegal-cell count taken from the detailed-placement log, and states that no legality check result exists
