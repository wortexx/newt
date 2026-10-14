# pnr-flow Specification

## Purpose

Defines what the OpenROAD place-and-route flow must do when run unattended: complete without human intervention on the project's pinned OpenROAD version, survive its known failure modes, checkpoint its progress, and report how far routing got — on a design that is known not to close timing or converge detailed routing.

## Requirements

### Requirement: P&R flow completes unattended on the pinned OpenROAD version

The system SHALL provide a P&R flow entry point that runs the OpenROAD backend (floorplan through routing) headlessly, with no interactive input, GUI, or manual intervention, against the OpenROAD version shipped in the `newt-eda` image. A flow stage that is incompatible with that version's command API SHALL be adapted or replaced, not left to error out mid-run.

#### Scenario: Full unattended run

- **WHEN** the P&R flow is invoked headlessly in the `newt-eda` container on the synthesized Basilisk netlist
- **THEN** it proceeds from floorplan through its final stage and exits with a status code, without ever waiting on input or opening a GUI

#### Scenario: No unbounded repair loops

- **WHEN** the flow reaches a timing-repair step on a design that cannot close timing (WNS ≈ −2.5 ns)
- **THEN** the step completes within its configured bounds (or is skipped by configuration) rather than iterating indefinitely

### Requirement: Known-flaky steps are retried, not fatal on first failure

For a step with a known intermittent failure mode (`remove_buffers` segfaults on roughly one run in three), the system SHALL retry the step at least once from the most recent checkpoint before declaring the run failed.

#### Scenario: remove_buffers crashes once

- **WHEN** `remove_buffers` crashes on its first attempt
- **THEN** the flow retries it from the preceding checkpoint and continues if the retry succeeds

#### Scenario: remove_buffers crashes repeatedly

- **WHEN** `remove_buffers` crashes on the retry as well
- **THEN** the flow exits non-zero, and the checkpoint preceding the failed step is preserved for offline diagnosis

### Requirement: Flow checkpoints each major stage and can resume from a checkpoint

The system SHALL save a named checkpoint after each major stage (floorplan, power grid, placement, CTS, global route, detailed route), and SHALL support starting a run from a chosen checkpoint instead of from the beginning. A resumed run SHALL produce the same downstream behavior as an uninterrupted run — in particular, routing-layer configuration lost across a checkpoint reload SHALL be re-applied before routing continues.

#### Scenario: Resume after interruption

- **WHEN** a run is interrupted after CTS and a new run is started from the CTS checkpoint
- **THEN** the flow continues from CTS without re-running earlier stages

#### Scenario: Resumed run routes on the correct layers

- **WHEN** a run resumes from a post-CTS checkpoint and proceeds to routing
- **THEN** routing respects the same signal-layer restrictions as an uninterrupted run (no guides on excluded top layers, no `DRT-0155`-class failures caused by the reload)

### Requirement: Success is gated through global route; detailed route is best-effort

The flow SHALL exit 0 when floorplan, placement, CTS, and global routing all complete, regardless of detailed-routing convergence. Detailed routing SHALL run with a bounded iteration budget, and its outcome (converged, or stopped at the budget with a DRC-violation count trajectory) SHALL be reported without affecting the exit code. A failure in any stage up to and including global route SHALL exit non-zero.

#### Scenario: Global route completes, detailed route does not converge

- **WHEN** global routing completes cleanly and detailed routing stops at its iteration budget with violations remaining
- **THEN** the flow exits 0 and the report states the iteration count and the DRC-violation trajectory

#### Scenario: A gated stage fails

- **WHEN** placement, CTS, or global routing fails
- **THEN** the flow exits non-zero and identifies the failed stage in its output

### Requirement: Flow emits end-of-run reports

The system SHALL produce, at the end of a run (successful or not), the reports that exist at that point — at minimum utilization/area, timing (setup/hold summary), and routing status — in files a CI job or a human can collect without re-running the flow.

#### Scenario: Reports after a gated-success run

- **WHEN** a run exits 0
- **THEN** area, timing, and routing reports for the completed stages exist as files under the flow's report directory

#### Scenario: Reports after a failed run

- **WHEN** a run exits non-zero partway through
- **THEN** the reports and logs produced up to the failure point still exist on disk

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

### Requirement: Power reports state their activity assumption

Every power figure in the flow's reports SHALL be computed under switching activity that the report states explicitly. Without a workload activity file, that is a single uniform activity applied to every net. The report SHALL label such a figure as uniform-activity and comparative only, not as the design's workload power. The flow SHALL NOT report power computed from OpenSTA's propagated default activity, because that propagation does not converge on this design and its result depends on the netlist's structure rather than on its logic. The activity setting SHALL apply only to the power report, and SHALL NOT change any later step of the same stage.

#### Scenario: Stage report carries a labelled power figure

- **WHEN** a P&R stage writes its end-of-stage report
- **THEN** the report's power section names the activity assumption (uniform activity, its value and duty) and states that the figure is comparative, not workload power

#### Scenario: Comparable across netlists

- **WHEN** two netlists that differ only by added logic are reported at the same stage with the same settings
- **THEN** the power difference between them follows the added logic (more cells and flip-flops give more power), with neither collapsing to near zero nor jumping by an order of magnitude

#### Scenario: Activity setting does not leak into the flow

- **WHEN** a stage runs further commands after writing its report (for example a timing repair)
- **THEN** those commands see the same activity state as before the report was written

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

### Requirement: Standard cells stay out of the margins between macros and the core edge

The floorplan SHALL block standard-cell placement in every gap between a placed macro and the core edge that is no wider than a configured margin width, along the full length of the macro's side facing that edge. Where a macro is within the margin width of two core edges, the floorplan SHALL also block the corner between the macro and the core's corner, which the two side margins and the core edges would otherwise enclose. The default margin width SHALL cover the padding the floorplan leaves between macros and the core edge on every side of the core. A margin width of 0 SHALL turn the blocking off, reproducing the floorplan from before this requirement. The blocking SHALL hold for global placement, every legalization and every repair step that inserts cells, so that no standard cell is ever placed in such a gap. It SHALL NOT block any other area: gaps between two macros and the open core area keep their rows.

After detailed placement, the run SHALL report:

- the number of standard cells inside the blocked margins;
- the number of standard cells in channels between two macros that are no wider than a configured channel width, and that width.

A non-zero margin count SHALL be a named warning in the run's output. Neither count SHALL change the run's exit status.

#### Scenario: Margins stay empty

- **WHEN** the P&R flow runs on the current Basilisk floorplan with default settings
- **THEN** the report after detailed placement shows 0 cells in the macro margins and states the count of cells in narrow channels between macros, and no warning is raised

#### Scenario: Macro near a core corner

- **WHEN** a macro lies within the margin width of two core edges
- **THEN** both side margins and the corner square between the macro and the core's corner are blocked, so no enclosed pocket remains where a cell could be placed

#### Scenario: A cell reaches a margin

- **WHEN** a cell ends up inside a blocked margin after detailed placement, for example after a floorplan edit
- **THEN** the run's output contains a warning naming the margin count, and the run's exit status is still decided only by the stage gates

#### Scenario: Blocking turned off

- **WHEN** a run is configured with a margin width of 0
- **THEN** no margin is blocked, the stage log says so, and the report after detailed placement still states both counts

#### Scenario: Channels between macros are untouched

- **WHEN** two macros are separated by a channel, whatever its width
- **THEN** that channel keeps its placement rows, and any cells placed there appear only in the narrow-channel count

### Requirement: The run reports nets routed outside the core

After global routing, the run SHALL report the number of nets that have at least one global-route guide outside the core area, alongside the existing congestion summary. The figure SHALL be produced whenever global routing writes its route guides, whether or not later stages run, and SHALL NOT change the run's exit status.

#### Scenario: Report after global routing

- **WHEN** global routing completes and writes its route guides
- **THEN** the stage's output states how many nets have guides outside the core area

#### Scenario: Global routing fails

- **WHEN** global routing fails before writing route guides
- **THEN** no figure is reported, the output says it could not be computed, and the run fails on the stage gate as before
