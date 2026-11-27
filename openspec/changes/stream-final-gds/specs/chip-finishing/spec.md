# Spec Delta

## Purpose

Turns the routed design that place and route produces into layout data, a GDS with the geometry of every cell, so the die can be viewed, checked by DRC and extended with seal ring and artwork.

## ADDED Requirements

### Requirement: Stream the routed DEF to GDS

The flow SHALL provide one command that converts a routed DEF into a gzip-compressed GDS of the whole chip, with top cell `iguana_chip`, and writes a log of the conversion. Without arguments it SHALL read the flow's own `basilisk.final.def`. It SHALL also accept any other DEF path, so a DEF from a CI run can be streamed locally.

#### Scenario: Stream the flow's own DEF

- **GIVEN** `target/ihp13/openroad/out/basilisk.final.def` exists
- **WHEN** the GDS command runs without arguments
- **THEN** it writes `basilisk.gds.gz` with top cell `iguana_chip` and a stream log, and exits 0

#### Scenario: Stream a DEF from elsewhere

- **WHEN** the GDS command runs with the path of a DEF downloaded from a P&R lane run
- **THEN** it streams that DEF instead of the flow's own

#### Scenario: No DEF

- **WHEN** the GDS command runs and the DEF it was given does not exist
- **THEN** it exits non-zero with an error naming the missing path, and writes no GDS

### Requirement: Cells carry their own geometry

Every cell the DEF instantiates SHALL appear in the GDS with the geometry from its library or macro GDS: the standard cells, every SRAM size the floorplan can place, and the Hyperbus delay line. Routing, special routing (the power grid) and vias SHALL come from the DEF.

#### Scenario: Standard cells, SRAMs and delay line are filled

- **WHEN** run `45365266924`'s DEF is streamed
- **THEN** no instance of a standard cell, an `RM_IHPSG13_1P_*` SRAM or `delay_line_D4_O1_6P000` refers to an empty cell

### Requirement: Merged macros cannot replace the design's cells

When a macro GDS is merged, a sub-cell of that macro whose name matches a cell already in the layout, or a sub-cell of another merged macro, SHALL NOT replace that cell. Only the macro's own top cell SHALL bind to the DEF's instances of it.

#### Scenario: Same-named via cells in a macro and in the DEF

- **GIVEN** the delay-line GDS contains a cell `VIA_Via1_YX_so` and the DEF's routing uses a via of the same name
- **WHEN** the DEF is streamed
- **THEN** the DEF's vias keep their own geometry and the delay line keeps its own

#### Scenario: Shared sub-cell names between SRAM sizes

- **GIVEN** two SRAM GDS files each contain a sub-cell `RM_IHPSG13_1P_BITKIT_CELL` with different content
- **WHEN** both are merged
- **THEN** each SRAM keeps its own version of that sub-cell

### Requirement: Empty instantiated cells fail the stream except allowed IO cells

The stream SHALL fail if any cell the DEF instantiates is empty, except cells on an explicit IO allow-list (the pre-release IO cells, which have no public GDS). It SHALL log the empty allowed cells and their instance count. Empty sub-cells inside a macro's GDS SHALL NOT fail it.

#### Scenario: IO pads without GDS

- **WHEN** the DEF is streamed with the pinned PDK
- **THEN** the IO cells (`ixc013_*`, `vddpad`, `gndpad`, `vddcore`, `gndcore`, `corner`, `filler*u`, `power_cut*`) are empty, the log lists them with their instance count, and the stream succeeds

#### Scenario: A standard cell has no GDS

- **GIVEN** the DEF instantiates a cell that is in the LEF but missing from every merged GDS, and it is not on the IO allow-list
- **WHEN** the DEF is streamed
- **THEN** the stream exits non-zero and the log names that cell

#### Scenario: Empty sub-cells shipped inside an SRAM

- **GIVEN** an SRAM GDS contains sub-cells with no shapes, as shipped
- **WHEN** the DEF is streamed
- **THEN** those sub-cells do not fail the stream

### Requirement: Only the design's cells in the GDS

The GDS SHALL have exactly one top cell, `iguana_chip`. Library cells that the merged GDS files bring in but the design does not use SHALL NOT be in the output.

#### Scenario: Unused standard cells dropped

- **WHEN** the standard-cell GDS is merged and the design does not use `sg13g2_sighold`
- **THEN** the output GDS has no `sg13g2_sighold` cell and only one top cell

### Requirement: GDS layers follow the PDK

Routing, via and pin shapes SHALL be written on the PDK's drawing layers for their metal or via (the IHP SG13G2 GDS layer numbers). Top-level pin names SHALL be written as text on the PDK's text layer of the pin's metal.

#### Scenario: Pin labels on the top level

- **WHEN** the GDS is opened in KLayout with the PDK's layer properties
- **THEN** each top-level pin from the DEF has its shape on the metal's drawing layer and its name as a text on that metal's text layer

#### Scenario: Signoff DRC result unchanged against the probe

- **WHEN** the GDS of run `45365266924` is checked with the full-die KLayout DRC sweep used on 2026-11-24/25
- **THEN** the non-density results match that sweep's: 1,183,332 `Cnt.a` inside the SRAMs and 996/902/388/316 `Pas.a`/`Pas.b`/`M2.a`/`forbidden.PEmWind` inside the delay lines, and nothing outside the IP
