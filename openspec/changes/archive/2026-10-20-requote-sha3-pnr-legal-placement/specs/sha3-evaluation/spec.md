# Spec Delta

## ADDED Requirements

### Requirement: SoC P&R comparison from legal, like-for-like placements

Every SoC place-and-route figure compared between the reference SoC and the SoC with the SHA-3 blocks SHALL come from runs whose placement passed the flow's gated legality check after both `dpl` and `cts`. Both runs SHALL use the same flow revision, the same die size and the same flow inputs. Flow comments may differ, but nothing that changes behaviour. The reference SHALL be the same SoC without the SHA-3 hardware: CV-X-IF disabled, no Keccak instances, and no external AXI subordinate for the accelerator. Its synthesized netlist SHALL match the earlier pre-coprocessor reference within the known ABC mapping-noise band, or the report SHALL state the deviation. The report SHALL name, for both runs:

- the run identifiers;
- the commit;
- the die size;
- that placement was legal.

Figures quoted earlier from placements that failed the legality check SHALL NOT be used as current results. They MAY be kept only when they are labelled as superseded, together with the reason.

#### Scenario: Both sides legal and on the same die

- **WHEN** the SoC P&R section of the report is generated from a reference run and a SHA-3 run
- **THEN** it states for each run that placement was legal after `dpl` and `cts`, and gives the die size, which is the same for both

#### Scenario: An illegal or mismatched run is rejected

- **WHEN** either run lacks a passed legality check after `dpl` or `cts`, or the two runs report different die sizes
- **THEN** the generator does not emit a comparison table and fails with a message naming the run and the missing or mismatched item

#### Scenario: Reference netlist is the pre-coprocessor SoC

- **WHEN** the reference branch is synthesized
- **THEN** its whole-SoC cells, area and flip-flops are compared with the earlier pre-coprocessor reference synthesis, and the difference is reported with the noise band

#### Scenario: Superseded figures are labelled

- **WHEN** the evaluation summary keeps a figure from the earlier illegal-placement runs
- **THEN** that figure is marked as superseded, together with its runs and the reason (overlapping cells), and is not used to derive any current figure such as the achieved period
