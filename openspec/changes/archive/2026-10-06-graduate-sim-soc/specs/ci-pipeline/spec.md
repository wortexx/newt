## MODIFIED Requirements

### Requirement: Real jobs are required status checks

The system SHALL configure `main`'s branch protection so that the statuses of every fast-lane job that evaluates its real condition — `lint`, `sw`, `sim-unit`, `synth-coproc` and `sim-soc` — are required to pass before a PR can merge.

#### Scenario: lint or sw fails on a PR targeting main

- **WHEN** the `lint` or `sw` job fails on a PR targeting `main`
- **THEN** the merge button is blocked by branch protection until the job passes

#### Scenario: A graduated job fails on a PR targeting main

- **WHEN** any of `sim-unit`, `synth-coproc` or `sim-soc` fails on a PR targeting `main`
- **THEN** the merge button is blocked by branch protection until the job passes

#### Scenario: Required list matches the gating jobs

- **WHEN** `main`'s required-status-checks list is inspected
- **THEN** it contains exactly `lint`, `sw`, `sim-unit`, `synth-coproc` and `sim-soc`

### Requirement: A stub job graduates to gating only via an explicit follow-up

Once the blocker a stub job names is resolved (coprocessor RTL exists and passes its own tests, or the Verilator green light passes), the system SHALL require that job to actually evaluate its real condition and fail on a real regression, and SHALL require it be added to `main`'s required status checks at that point — not automatically, but as a deliberate follow-up change.

For the coprocessor checks, the graduating change SHALL define their real conditions as follows. `sim-unit` SHALL run the unit testbenches of every block under `hw/coproc/` in an open-source simulator, and SHALL fail if any testbench reports a mismatch against its reference model or does not complete. `synth-coproc` SHALL synthesize every block under `hw/coproc/` on its own against the project's IHP SG13G2 cell library. It SHALL fail if synthesis errors, if the final synthesis `CHECK` report lists one or more problems, or if any of the flow's `check` passes reports a structural problem (a logic loop, conflicting drivers, or a used-but-undriven wire). The final report alone does not suffice: later passes resolve such structures before it runs. Neither job SHALL depend on the self-hosted runner or on a licensed simulator.

For the SoC check, `sim-soc` SHALL build the Verilator SoC model with the SoC's own CVA6 configuration applied, together with the test programs it runs, from the PR's own sources. It SHALL then run at least the platform boot program (`helloworld.spm.elf`) and one SHA-3 known-answer program that executes the CV-X-IF coprocessor instructions (`sha3_smoke.spm.elf`). It SHALL fail if the model or a program fails to build, if any program reports a failing exit code, if any run exceeds its simulation timeout, or if a run cannot start, for example because a program binary is missing. A failure of the model build or of a simulation run SHALL NOT be retried; only the network dependency checkout MAY be retried. `sim-soc` SHALL run on a GitHub-hosted runner, without the self-hosted VM or a licensed simulator.

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

#### Scenario: SoC boot regression fails sim-soc

- **WHEN** a pull request changes the SoC, its configuration or the Verilator harness so that `helloworld.spm.elf` no longer prints its output and exits 0 in the Verilator model
- **THEN** `sim-soc` fails, and because it is a required status check the PR cannot merge

#### Scenario: Coprocessor integration regression fails sim-soc

- **WHEN** a pull request breaks the CV-X-IF path between CVA6 and the Keccak coprocessor so that `sha3_smoke.spm.elf` reports a digest mismatch or hangs
- **THEN** `sim-soc` fails with that program's output and exit status visible in the job log

#### Scenario: Missing test program is a failure, not a retry

- **WHEN** a `sim-soc` run cannot start because its program binary or the model is missing or fails to build
- **THEN** the job fails on the first occurrence without rebuilding or retrying, and its log names the failing step rather than any former blocker

#### Scenario: Graduated sim-soc stays on a hosted runner

- **WHEN** the graduated `sim-soc` job runs
- **THEN** it runs on a GitHub-hosted runner and does not start or wait for the self-hosted VM

## ADDED Requirements

### Requirement: A future stub job runs, names its blocker, and never gates merges

No fast-lane job is stubbed today. If a check is added later whose real implementation depends on work that has not landed yet, the system SHALL still run a job under that check's final name, SHALL make the job print which specific blocker it is waiting on, and SHALL make the job exit 0 regardless of the condition it cannot yet evaluate. Such a job SHALL NOT be added to `main`'s required status checks while stubbed. It graduates only through the explicit follow-up the graduation requirement describes.

#### Scenario: A stub job runs before its blocker clears

- **WHEN** a stubbed job runs on a PR and the work it depends on has not landed
- **THEN** the job exits 0 and its output names the blocker it is waiting on

#### Scenario: A stub job is never a required status check

- **WHEN** `main`'s required-status-checks list is inspected while a job is stubbed
- **THEN** that job's name does not appear in the required list

## REMOVED Requirements

### Requirement: Stubbed jobs run, self-report their blocker, and never gate merges

**Reason**: All three jobs it named have graduated: `sim-unit` and `synth-coproc` in `sha3-cvxif-coprocessor`, and `sim-soc` in this change. Its scenarios describe stub states that no longer exist, so keeping them would leave the spec contradicting the required-checks requirement.

**Migration**: The general contract for any future stub is carried by the added requirement "A future stub job runs, names its blocker, and never gates merges". The graduated jobs' real conditions are in "A stub job graduates to gating only via an explicit follow-up".
