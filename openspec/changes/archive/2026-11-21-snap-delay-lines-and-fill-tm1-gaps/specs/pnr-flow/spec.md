# Spec Delta

## ADDED Requirements

### Requirement: The floorplan places the delay-line macros on the standard-cell site grid

The floorplan SHALL place every Hyperbus delay-line macro with its origin on the site grid and the row grid of the standard-cell rows it covers, no closer to the core edge than the floorplan's padding. The floorplan log SHALL record each instance's position. A delay-line instance whose origin is off either grid after placement SHALL fail the floorplan stage before its checkpoint is saved.

#### Scenario: Delay lines on the grid

- **WHEN** the floorplan stage runs on a design with the two Hyperbus delay lines placed at the core's west edge
- **THEN** each delay line's x lies an integer number of sites from the rows' origin and at least the floorplan padding from the core edge, its y lies on the double-row grid, and the log records both positions

#### Scenario: Off-grid placement

- **WHEN** a floorplan edit places a delay-line instance with its origin off the site grid or the row grid
- **THEN** the floorplan stage fails without saving its checkpoint, and its log names the instance and its position

#### Scenario: Design without Hyperbus

- **WHEN** the design has no delay-line instance
- **THEN** the floorplan places and checks nothing for the delay lines and continues

### Requirement: The floorplan closes same-net TopMetal1 gaps in the supply grid

After the power grid is generated and before its connectivity check, the floorplan SHALL fill every gap between two TopMetal1 shapes of the same supply net whose facing edges overlap and lie less than the layer's minimum spacing apart. It fills the gap with a TopMetal1 shape of that net. The floorplan log SHALL record the number of fills. A fill that would touch a TopMetal1 shape of another net SHALL fail the floorplan stage before its checkpoint is saved.

#### Scenario: Gaps over the stacked SRAM columns

- **WHEN** the floorplan stage generates the power grid on the current Basilisk floorplan
- **THEN** the TopMetal1 via pads that end 0.26, 0.78 and 1.14 µm apart over both stacked SRAM columns are joined, and the log records the number of fills

#### Scenario: Fill would short

- **WHEN** a gap between two same-net TopMetal1 shapes also contains or touches a TopMetal1 shape of another net
- **THEN** the floorplan stage fails without saving its checkpoint, and its log names both nets and the gap's location

#### Scenario: No gaps

- **WHEN** no two same-net TopMetal1 supply shapes lie closer than the minimum spacing
- **THEN** the floorplan adds no shape, logs a count of 0, and continues
