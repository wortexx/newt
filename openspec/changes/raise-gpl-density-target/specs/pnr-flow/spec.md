## ADDED Requirements

### Requirement: The run reports how global placement ended

After detailed placement, a run SHALL report whether global placement's final pass converged or reverted after a divergence (and at what overflow), the final placement-area inflation, the utilization entering detailed placement, and the number of illegal cells the legalizer starts from. A final-pass revert SHALL be a named warning in the run's output, not a failure, so that an unconverged placement is noticed before it shows up as a legalization timeout. The report SHALL be produced whether or not detailed placement succeeded, from what detailed placement logs before it legalizes.

#### Scenario: Placement converges

- **WHEN** the P&R flow runs on the current Basilisk netlist with the default placement settings
- **THEN** the report shows the final global-placement pass ending without a revert, and detailed placement and CTS complete within their configured stage timeouts

#### Scenario: Placement reverts after a divergence

- **WHEN** global placement's final pass reverts to a snapshot after a divergence
- **THEN** the run's output contains a warning naming the overflow it reverted to and the illegal cells detailed placement starts from, and the run's exit status is still decided only by the stage gates

#### Scenario: Detailed placement times out

- **WHEN** detailed placement exceeds its stage timeout
- **THEN** the report is still printed, with the utilization and the illegal-cell count taken from the detailed-placement log
