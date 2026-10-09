# Spec Delta

## ADDED Requirements

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
