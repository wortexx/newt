# Spec Delta

## MODIFIED Requirements

### Requirement: The floorplan can remove the power grid's channel-repair straps

The staged flow SHALL accept a setting that keeps or removes the channel-repair straps the power-grid generator adds: every TopMetal2 supply strap shorter than the core, with the via stacks under it. By default the staged flow SHALL remove them. Keeping them SHALL give the same power grid as a run made before this setting existed. Any other value SHALL fail the floorplan stage, with an error naming the setting. The floorplan log SHALL record whether the straps were removed.

#### Scenario: Default

- **WHEN** the staged flow runs from `floorplan` without the channel-repair setting
- **THEN** the power grid has no TopMetal2 supply strap shorter than the core, and the floorplan log records that repair was off

#### Scenario: Straps kept

- **WHEN** the flow runs with channel repair on
- **THEN** the power grid keeps its channel-repair straps as before this setting existed, and the floorplan log records that repair was on

#### Scenario: Straps removed

- **WHEN** the flow runs with channel repair off
- **THEN** the power grid has no TopMetal2 supply strap shorter than the core and no via stack left under a removed strap, no Metal1 rail is removed, and the floorplan log records that repair was off

#### Scenario: Invalid value

- **WHEN** the channel-repair setting names neither on nor off
- **THEN** the floorplan stage fails with an error naming the setting, before the power grid is generated

### Requirement: Global routing can hold back extra Metal5 at the SRAMs' ends

The flow SHALL accept an extra share of Metal5 capacity that global routing holds back in fixed-width strips at the short ends of SRAMs, on top of the whole-footprint hold-back, and a setting choosing the ends: both ends of every SRAM, or only the end holding the bit-0 data-input pin of each SRAM wider than tall. The default SHALL be a share of 0.5 on the pin end. An invalid share or end choice SHALL fail the stage that reads it, naming the setting.

#### Scenario: Default

- **WHEN** the flow runs without either SRAM-end setting
- **THEN** every routing stage holds back a further half of the Metal5 capacity left in one strip per SRAM wider than tall, at the end holding its bit-0 data-input pin, adds no strip to SRAMs taller than wide, and logs the share, the end choice, the strip width and the strip count

#### Scenario: Hold-back set

- **WHEN** the flow runs with the end choice set to both ends and a share of 0.5
- **THEN** every routing stage holds back a further half of the Metal5 capacity left in a strip at both short ends of every SRAM, logs two strips per SRAM, and changes no other layer and no Metal5 capacity outside the strips

#### Scenario: Pin-end strips follow the macro's orientation

- **WHEN** two SRAMs wider than tall are placed rotated 180° from each other, with the pin-end choice
- **THEN** each one's strip lies at the short end nearest its own bit-0 data-input pin, so the two strips are at opposite ends

#### Scenario: No hold-back

- **WHEN** the flow runs with an SRAM-end share of 0
- **THEN** global routing adds no end strips, whatever the end choice

#### Scenario: Invalid value

- **WHEN** the SRAM-end share is not a number, is negative, or is 1 or more, or the end choice names neither both ends nor the pin end
- **THEN** the stage that reads it fails with an error naming the setting, before any routing runs
