## ADDED Requirements

### Requirement: Model is built against the SoC's CVA6 configuration

The Verilator model build SHALL simulate CVA6 with the same package-level configuration the SoC is synthesized with: the project's rewrite of the CVA6 configuration package, as applied by the hardware-configuration step. When that rewrite has not been applied to the checked-out CVA6 sources, the model build SHALL fail before verilating, with a message that names the step to run. It SHALL NOT silently build a model with stock CVA6 parameters.

#### Scenario: Fresh checkout without the configuration step

- **WHEN** the model build target is invoked on a fresh dependency checkout where the CVA6 configuration rewrite has not been applied
- **THEN** the build exits non-zero before verilating, and its error names the configuration target to run first

#### Scenario: Configuration applied

- **WHEN** the CVA6 configuration rewrite has been applied and the model build target is invoked
- **THEN** the model builds from the rewritten configuration package and exits 0
