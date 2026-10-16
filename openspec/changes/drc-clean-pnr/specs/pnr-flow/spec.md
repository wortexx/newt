# Spec Delta

## ADDED Requirements

### Requirement: Detailed routing reports the router's own violation counts

When detailed routing runs, the stage SHALL report the violation counts the router itself computed:

- the total after its final iteration;
- the total after each iteration;
- the final iteration's violations by type and by layer.

These figures SHALL come from the router's own output, never from counting entries in a DRC report file. Such a file may be capped and may not list every violation. The stage's status line SHALL carry the final total under a name that says it is the router's count. The figures SHALL be reported whether routing converged, stopped at its iteration budget or timed out after at least one iteration. Reporting SHALL NOT change the stage's outcome or the run's exit status.

#### Scenario: Routing stops at its budget with violations left

- **WHEN** detailed routing finishes its iteration budget with violations remaining
- **THEN** the stage status gives the router's final violation total, and the run's reports give the total after every iteration and the final table by type and layer

#### Scenario: The DRC report file is capped

- **WHEN** the router counts more violations than its DRC report file lists
- **THEN** every reported total equals the router's count, not the number of entries in the file

#### Scenario: Routing converges

- **WHEN** detailed routing reaches zero violations
- **THEN** the stage status reports a final total of 0 and the number of iterations it took
