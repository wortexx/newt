# Spec Delta

## MODIFIED Requirements

### Requirement: A stub job graduates to gating only via an explicit follow-up

Once the blocker a stub job names is resolved (coprocessor RTL exists and passes its own tests, or the Verilator green light passes), the system SHALL require that job to actually evaluate its real condition and fail on a real regression, and SHALL require it be added to `main`'s required status checks at that point — not automatically, but as a deliberate follow-up change.

For the coprocessor checks, the graduating change SHALL define their real conditions as follows. `sim-unit` SHALL run the unit testbenches of every block under `hw/coproc/` in an open-source simulator, and SHALL fail if any testbench reports a mismatch against its reference model or does not complete. `synth-coproc` SHALL synthesize every block under `hw/coproc/` on its own against the project's IHP SG13G2 cell library. It SHALL fail if synthesis errors, if the final synthesis `CHECK` report lists one or more problems, or if any of the flow's `check` passes reports a structural problem (a logic loop, conflicting drivers, or a used-but-undriven wire). The final report alone does not suffice: later passes resolve such structures before it runs. Neither job SHALL depend on the self-hosted runner or on a licensed simulator.

#### Scenario: Verilator green light starts passing

- **WHEN** the `verilator-sim-flow` blocker is resolved and `make ig-sim-verilator` passes on the green-light test
- **THEN** a follow-up change updates `sim-soc` to fail on a real regression and adds it to the required-status-checks list

#### Scenario: Coprocessor RTL lands and sim-unit graduates

- **WHEN** the change that adds the Keccak coprocessor and accelerator RTL under `hw/coproc/` merges
- **THEN** `sim-unit` runs those blocks' unit testbenches, fails the PR on any reference-model mismatch, and appears in `main`'s required status checks

#### Scenario: Coprocessor RTL lands and synth-coproc graduates

- **WHEN** a pull request changes a block under `hw/coproc/` so that its standalone synthesis reports a `CHECK` problem, for example a combinational loop that yosys `check` warns about during synthesis
- **THEN** `synth-coproc` fails, and because it is a required status check the PR cannot merge

#### Scenario: Graduated coprocessor jobs stay on hosted runners

- **WHEN** the graduated `sim-unit` or `synth-coproc` job runs
- **THEN** it runs on a GitHub-hosted runner and does not start or wait for the self-hosted VM
