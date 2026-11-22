# Spec Delta

## ADDED Requirements

### Requirement: The CTS stage reports each clock tree's shape

After building the clock trees, the CTS stage SHALL report, for every clock tree it built, the tree's root net, its H-tree depth, its number of tree buffers, how many of those buffers drive only one or two sinks, and the widest span of the sinks driven by one buffer of its deepest level. It SHALL write these to the stage log and as one line per tree to the run's stage-status file. The report SHALL NOT change the stage's exit status.

#### Scenario: Tree shape in the status file

- **WHEN** the CTS stage completes on the Basilisk design
- **THEN** the stage-status file has one line per clock tree, and the line for the register clock tree gives its depth, its buffer count, its count of buffers driving one or two sinks and its deepest level's widest sink span in µm

#### Scenario: A deeper tree is visible

- **WHEN** a run's register clock tree is deeper than a reference run's
- **THEN** the two runs' stage-status files show different depths and buffer counts, without reading either CTS log

### Requirement: The CTS stage keeps the shallower of two register clock trees

After building the clock trees, the CTS stage SHALL test the register clock tree, the tree with the most buffers, for near-empty levels: more than 10 % of its buffers driving only one or two sinks. When the test fires, the stage SHALL rebuild the trees once from the placement checkpoint with an alternative clustering setting and keep the build whose register tree has fewer such buffers. A rebuild SHALL NOT count as a stage failure.

#### Scenario: Rebuild is logged

- **WHEN** the stage rebuilds the trees
- **THEN** the stage log and the stage-status file name each build's settings and register tree shape, and say which build was kept

#### Scenario: Two placements that differ by a 0.16 µm macro move

- **WHEN** the CTS stage runs with the lane defaults on run `44382400639`'s and run `44708127322`'s `dpl` checkpoints, which differ by the delay lines' 0.16 µm move
- **THEN** both kept register clock trees have the same H-tree depth, and neither has more buffers driving one or two sinks than the other by more than 1 % of its tree buffers

#### Scenario: No rebuild when the first tree passes

- **WHEN** the first build's register clock tree has 10 % or fewer of its buffers driving one or two sinks
- **THEN** the stage keeps that build, runs CTS once, and its clock power is the same as with the previous settings

#### Scenario: Both builds deep

- **WHEN** both builds' register clock trees fail the test
- **THEN** the stage keeps the build with fewer buffers driving one or two sinks and completes, and the status file records that both failed

#### Scenario: Override

- **WHEN** a run sets the clustering setting through its environment variable, or turns the rebuild off
- **THEN** CTS uses that value without a rebuild, and the stage log names every CTS setting in use
