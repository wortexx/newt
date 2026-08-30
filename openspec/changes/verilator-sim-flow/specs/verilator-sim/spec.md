# verilator-sim Specification (delta)

## Purpose

Defines the open-source simulation lane: how a Verilator model of the SoC is built from the Bender dependency graph, how a test binary and boot/preload configuration are supplied at runtime, and what observable behavior constitutes a passing simulation — so CI and developers can run RTL simulations without a Questa license.

## ADDED Requirements

### Requirement: Verilator model build from the Bender graph

The build system SHALL provide a Make target that builds a self-contained Verilator simulation executable of the SoC RTL from the Bender dependency graph, using the same dependency pins (`Bender.lock`) as the Questa and synthesis flows. The build SHALL run inside the `newt-eda` container with no tools beyond those the image provides.

#### Scenario: Model builds from a clean checkout

- **WHEN** the Verilator build target is invoked in the `newt-eda` container on a clean checkout (after dependency checkout)
- **THEN** it produces a runnable simulation executable and exits 0, without requiring Questa or any licensed tool

#### Scenario: Rebuild tracks RTL and manifest changes

- **WHEN** an RTL source in the dependency graph or `Bender.yml`/`Bender.lock` changes and the build target is re-invoked
- **THEN** the simulation executable is rebuilt to reflect the change (no manual clean required for source-level changes)

### Requirement: Runtime test configuration via plusargs

The simulation executable SHALL accept the test configuration at runtime — not baked in at compile time — covering at least: the test binary path (ELF), the boot mode, and the preload mode, mirroring the semantics of the Questa flow's `BINARY` / `BOOTMODE` / `PRELMODE` controls for the modes the Verilator lane supports. Changing the test binary SHALL NOT require re-verilating the model.

#### Scenario: Same model runs different binaries

- **WHEN** the simulation executable is invoked twice with two different ELF paths and no intervening rebuild
- **THEN** each run executes its respective binary

#### Scenario: Unsupported configuration is rejected clearly

- **WHEN** the simulation executable is invoked with a boot/preload mode the Verilator lane does not support (e.g., a mode requiring the hyperram model)
- **THEN** it exits non-zero with a message naming the unsupported mode, rather than hanging or silently misbehaving

### Requirement: Pass/fail semantics usable by CI

A simulation run SHALL communicate its result through its process exit code: 0 when the executed test program signals success through the platform's exit mechanism, non-zero when the test signals failure or the simulation cannot complete. UART output from the simulated SoC SHALL be captured and emitted on the simulator's stdout so test output is visible in logs. Runs SHALL be boundable by a timeout after which a non-completed simulation counts as failed.

#### Scenario: Green-light boot test passes

- **WHEN** the simulation executable runs `sw/tests/helloworld.spm.elf` in SPM boot configuration
- **THEN** the program's "Hello World!" UART output appears on stdout and the simulator process exits 0

#### Scenario: Failing test propagates failure

- **WHEN** the executed test binary signals a non-zero exit status via the platform exit mechanism
- **THEN** the simulator process exits non-zero

#### Scenario: Hung simulation does not block CI forever

- **WHEN** a simulation makes no progress toward test completion within the configured timeout
- **THEN** the run terminates and is reported as failed (non-zero exit)

### Requirement: Coexistence with the Questa flow

Adding the Verilator lane SHALL NOT change the behavior of the existing Questa targets (`ig-sim-rtl` and siblings): the same checkout SHALL still run the Questa flow unchanged for waveform debugging, including the hyperram-backed full-chip fixture. Verilator-specific sources and workarounds SHALL be confined to the Verilator lane (harness layer, Verilator config/waiver files, or `VERILATOR`-guarded code), not applied unconditionally to shared RTL.

#### Scenario: Questa flow unaffected

- **WHEN** the Questa target `ig-sim-rtl` is run on a checkout containing the Verilator flow
- **THEN** it compiles and runs exactly as before the change, with no new sources injected into its compile scripts

#### Scenario: Verilator workarounds stay out of the synthesis input

- **WHEN** the pickle/synthesis flow (`morty → svase → sv2v → yosys`) runs on a checkout containing the Verilator flow
- **THEN** its input file set and output are unchanged by the Verilator lane's additions
