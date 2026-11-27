# Spec Delta

## ADDED Requirements

### Requirement: P&R lane publishes the streamed GDS

When a P&R run produces a routed DEF, the lane SHALL stream it to GDS and upload the gzipped GDS and its stream log as a workflow artifact separate from the DEF, with bounded retention. A failed stream SHALL be reported in the run summary and SHALL NOT change the run's result. Without a DEF, the lane SHALL skip the stream.

#### Scenario: Routed run publishes a GDS

- **WHEN** a P&R run produces `basilisk.final.def`
- **THEN** a `basilisk-pnr-gds` artifact with `basilisk.gds.gz` and the stream log is downloadable from the run, and the summary states the GDS size and the number of empty IO cell instances

#### Scenario: Stream fails on a routed run

- **GIVEN** the P&R flow exits 0 and produced a DEF
- **WHEN** the GDS stream exits non-zero
- **THEN** the run is not marked failed, the summary states that the stream failed, and the stream log is still uploaded

#### Scenario: No DEF, no stream

- **WHEN** a P&R run ends without a routed DEF
- **THEN** the stream step does not run, and the summary's existing "no DEF" line is the only report of it
