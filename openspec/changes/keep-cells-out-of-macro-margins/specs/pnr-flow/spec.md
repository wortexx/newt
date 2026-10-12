## ADDED Requirements

### Requirement: Standard cells stay out of the margins between macros and the core edge

The floorplan SHALL block standard-cell placement in every gap between a placed macro and the core edge that is no wider than a configured margin width, along the full length of the macro's side facing that edge. The default margin width SHALL cover the padding the floorplan leaves between macros and the core edge on every side of the core. A margin width of 0 SHALL turn the blocking off, reproducing the floorplan from before this requirement. The blocking SHALL hold for global placement, every legalization and every repair step that inserts cells, so that no standard cell is ever placed in such a gap. It SHALL NOT block any other area: gaps between two macros and the open core area keep their rows.

After detailed placement, the run SHALL report:

- the number of standard cells inside the blocked margins;
- the number of standard cells in channels between two macros that are no wider than a configured channel width, and that width.

A non-zero margin count SHALL be a named warning in the run's output. Neither count SHALL change the run's exit status.

#### Scenario: Margins stay empty

- **WHEN** the P&R flow runs on the current Basilisk floorplan with default settings
- **THEN** the report after detailed placement shows 0 cells in the macro margins and states the count of cells in narrow channels between macros, and no warning is raised

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
