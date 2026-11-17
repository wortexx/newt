# Spec Delta

## ADDED Requirements

### Requirement: The floorplan connects the delay-line macros to the supply grid

After generating the power grid, the floorplan SHALL connect each supply pin rail of every Hyperbus delay-line macro to a core Metal1 rail of the same net that stops less than 1 µm from it. The floorplan log SHALL record how many connections it added. A delay-line supply pin rail that no same-net core rail reaches on either side SHALL fail the floorplan stage before its checkpoint is saved.

#### Scenario: Rails bridged

- **WHEN** the floorplan stage generates the power grid on a design with the two Hyperbus delay lines placed at the core's west edge
- **THEN** every VDD and VSS pin rail of both macros touches a core Metal1 rail of its net, and the floorplan log records the number of connections added

#### Scenario: Unreachable delay-line rail

- **WHEN** a delay-line supply pin rail has no same-net core Metal1 rail ending within 1 µm of it on either side
- **THEN** the floorplan stage fails without saving its checkpoint, and its log names the instance and the rail

#### Scenario: Design without Hyperbus

- **WHEN** the design has no delay-line instance
- **THEN** the floorplan adds no connections, logs a count of 0, and continues

### Requirement: Every floorplan run checks both supply grids for unconnected shapes

After the power grid is final, the floorplan SHALL check the VDD and the VSS grid for unconnected shapes and instances, whether or not the channel-repair straps were removed. It SHALL fail the stage before saving its checkpoint if either check reports anything. The log SHALL record each net's result.

#### Scenario: Clean grid

- **WHEN** neither supply net's check reports an unconnected shape or instance
- **THEN** the floorplan stage saves its checkpoint, and its log records that both checks passed

#### Scenario: Unconnected shape

- **WHEN** either supply net's check reports an unconnected shape or instance
- **THEN** the floorplan stage fails without saving its checkpoint, and its log names the net and each report
