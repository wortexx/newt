# Spec Delta

## ADDED Requirements

### Requirement: The floorplan can remove the power grid's channel-repair straps

The flow SHALL accept a setting that removes the channel-repair straps the power-grid generator adds: every TopMetal2 supply strap shorter than the core, with the via stacks under it. By default the straps SHALL stay, and the power grid SHALL match a run made before this setting existed. Any value other than keep or remove SHALL fail the floorplan stage, with an error naming the setting. The floorplan log SHALL record whether the straps were removed.

#### Scenario: Default

- **WHEN** the flow runs without the channel-repair setting
- **THEN** the power grid keeps its channel-repair straps as before this setting existed, and the floorplan log records that repair was on

#### Scenario: Straps removed

- **WHEN** the flow runs with channel repair off
- **THEN** the power grid has no TopMetal2 supply strap shorter than the core and no via stack left under a removed strap, no Metal1 rail is removed, and the floorplan log records that repair was off

#### Scenario: Invalid value

- **WHEN** the channel-repair setting names neither on nor off
- **THEN** the floorplan stage fails with an error naming the setting, before the power grid is generated

### Requirement: Removing the channel-repair straps disconnects nothing

When the straps are removed, the floorplan SHALL check both the VDD and the VSS grid for unconnected shapes before and after the removal, and SHALL fail the stage before saving its checkpoint if the check after the removal reports any shape or instance the check before did not. Shapes already unconnected before the removal SHALL NOT fail the stage. The floorplan log SHALL record each net's result and how many reports were already present. With the straps kept, this check SHALL NOT be required.

#### Scenario: Nothing disconnected

- **WHEN** the straps are removed and each supply net's check after the removal reports nothing the check before did not
- **THEN** the floorplan stage completes, and its log records that both checks passed with the count of reports already present before the removal

#### Scenario: Removal disconnects a shape

- **WHEN** the straps are removed and the check after the removal on either supply net reports a shape or instance the check before did not
- **THEN** the floorplan stage fails without saving its checkpoint, and its log names the net and the new reports

### Requirement: The floorplan reports partial-height TopMetal2 power straps

After generating the power grid, the floorplan SHALL log the number of TopMetal2 supply straps that do not span the core's full height. This SHALL be reporting only, and SHALL NOT change the stage's outcome.

#### Scenario: Strap count logged

- **WHEN** the floorplan stage generates the power grid, with channel repair on or off
- **THEN** its log records the count of TopMetal2 supply straps shorter than the core's height

### Requirement: Global routing can hold back extra Metal5 at the SRAMs' ends

The flow SHALL accept an extra share of Metal5 capacity that global routing holds back in a fixed-width strip at both short ends of every SRAM, on top of the whole-footprint hold-back. Default 0 leaves routing unchanged. A value outside [0, 1) SHALL fail the stage that reads it, naming the setting. Every stage applying the whole-footprint hold-back SHALL apply this one and log the share, strip width and strip count.

#### Scenario: Default

- **WHEN** the flow runs without the SRAM-end hold-back set
- **THEN** global routing adds no end strips, and the layout matches a run made before this setting existed

#### Scenario: Hold-back set

- **WHEN** the flow runs with an SRAM-end hold-back of 0.5
- **THEN** every routing stage holds back a further half of the Metal5 capacity left in each end strip, logs 0.5, the strip width and two strips per SRAM, and changes no other layer and no Metal5 capacity outside the strips

#### Scenario: Invalid value

- **WHEN** the SRAM-end hold-back is set to a value that is not a number, is negative, or is 1 or more
- **THEN** the stage that reads it fails with an error naming the setting, before any routing runs
