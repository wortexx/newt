# xcelium-sim Specification (delta)

## Purpose

Defines an Xcelium simulation lane for a restricted, offline VM that runs the SoC RTL with Cheshire's reference verification IP. The development host produces a self-contained bundle that is copied to the VM. One script on the VM runs every requested test. The VM hands back a single results archive with one verdict per test.

## ADDED Requirements

### Requirement: Self-contained simulation bundle

The build system SHALL provide a Make target that runs on the development host and produces exactly one archive file. That archive SHALL contain everything needed to compile and run the Xcelium simulation on a machine that has only Xcelium (`xrun`), `bash`, and standard POSIX utilities. The machine SHALL need no git, no Bender, no container runtime, no riscv toolchain, no network access, and no copy of the repository. The archive SHALL include:

- the simulator argument file
- every source file and include directory that argument file references
- the testbench
- the verification IP and its vendor sim models
- the DPI sources the verification IP imports
- the test binaries
- the run script

Every path inside the argument file SHALL be relative to the bundle root, and none SHALL be an absolute host path. The bundle SHALL be built from the same dependency pins (`Bender.lock`) as the Questa, Verilator, and synthesis flows.

#### Scenario: Bundle runs on a machine with nothing but Xcelium

- **WHEN** the bundle archive is extracted into an arbitrary directory on a machine with Xcelium and no repository checkout
- **THEN** the run script compiles and runs the simulation from that directory without referencing any file outside the extracted tree

#### Scenario: Host path leaks are rejected before archiving

- **WHEN** the bundle target generates an argument file in which any referenced file or include directory is absent from the staged bundle tree, or any entry is an absolute path
- **THEN** the target fails on the host with a message naming the offending entry, and produces no archive

#### Scenario: Bundle records its provenance

- **WHEN** a bundle archive is produced
- **THEN** it contains a manifest stating the source commit, whether the working tree was dirty, the `Bender.lock` content hash, the tool versions used to generate it, and the list of included test binaries

### Requirement: Single-script run with a single results archive

The bundle SHALL contain one run script that performs the full job on the VM:

1. compile and elaborate the design once
2. run each selected test binary against that one elaborated snapshot
3. write every log and result into one results directory
4. pack that directory into exactly one results archive file for copying back

By default the script SHALL run every test binary in the bundle. It SHALL accept a subset of those binaries by name. It SHALL accept the boot mode, preload mode, simulation timeout, and wave-dump selection as run-time settings, and none of these settings SHALL require re-generating the bundle.

#### Scenario: One command, one file back

- **WHEN** the run script is invoked with no arguments in an extracted bundle
- **THEN** it compiles once, runs every bundled test binary, and leaves exactly one results archive whose name identifies the bundle it came from

#### Scenario: Subset and settings chosen on the VM

- **WHEN** the run script is invoked with a subset of bundled test names and a non-default timeout
- **THEN** only those tests run, each bounded by the given timeout, and the design is not recompiled between them

#### Scenario: Compile failure still produces a results archive

- **WHEN** compilation or elaboration fails
- **THEN** the script still produces the results archive containing the compile log, marks every selected test `ERROR`, and exits non-zero

### Requirement: Per-test verdicts derived from the platform exit mechanism

For each executed test, the lane SHALL record exactly one verdict, as follows:

| Verdict | When |
|---|---|
| `PASS` | the test program signals exit code 0 through the platform's end-of-computation mechanism |
| `FAIL` | the test program signals a non-zero exit code |
| `TIMEOUT` | the test does not signal completion within the configured simulated-time bound |
| `ERROR` | the simulation could not run the test (compile/elaboration failure, unsupported configuration, missing binary) |

The results SHALL include a summary listing every test with its verdict and signalled exit code. The run script's own exit status SHALL be 0 only if every executed test is `PASS`. UART output from the simulated SoC SHALL appear in each test's log.

#### Scenario: Green-light boot test passes

- **WHEN** `helloworld.spm.elf` runs with boot mode 0 and JTAG preload (preload mode 0)
- **THEN** its log contains the program's "Hello World!" UART output, the summary reports `PASS` with exit code 0, and the run script exits 0

#### Scenario: Failing program reported as FAIL

- **WHEN** a bundled test program signals a non-zero exit code
- **THEN** the summary reports `FAIL` with that exit code, and the run script exits non-zero

#### Scenario: Hung simulation reported as TIMEOUT

- **WHEN** a test does not signal completion before the configured timeout
- **THEN** that test's simulation terminates, the summary reports `TIMEOUT`, and any remaining selected tests still run

#### Scenario: Unsupported configuration rejected clearly

- **WHEN** a test is run with a boot or preload mode this lane does not support
- **THEN** the test's log names the unsupported mode, and the summary reports `ERROR` rather than the test hanging until timeout

### Requirement: DUT parity with the Verilator lane

The Xcelium lane SHALL simulate the same design unit as the Verilator lane, which is `iguana_soc` built with the project's `iguana_pkg::CheshireCfg` and with the hyperbus controller tied off. It SHALL compile that design with the same IHP13 behavioral macro models, so that a behavioral difference between the two lanes points at the simulator or the harness and not at a different DUT. Test stimulus (clock, reset, JTAG, UART, and ELF preload) SHALL come from Cheshire's own verification IP, not from a lane-specific reimplementation.

#### Scenario: Same configuration as the Verilator lane

- **WHEN** the Xcelium bundle's design sources are compared with the Verilator lane's file list
- **THEN** both contain the same `iguana_soc` and dependency RTL sources, and both use the same hyperbus-tie-off and behavioral-model defines. They differ only in testbench, verification IP, and simulator-specific sources.

### Requirement: Coexistence with the other flows

Adding the Xcelium lane SHALL NOT change the Questa targets, the Verilator targets, or the pickle/synthesis input. Xcelium-specific sources and settings SHALL stay inside the lane's own directory and its generated bundle. Bundle and results artifacts, including the non-free vendor sim models they carry, SHALL NOT be committed to the repository.

#### Scenario: Other lanes unaffected

- **WHEN** the Questa compile script, the Verilator file list, and the pickle input file set are generated on a checkout containing the Xcelium lane
- **THEN** each is identical to what it was before the lane was added

#### Scenario: Generated artifacts stay untracked

- **WHEN** a bundle has been generated and a results archive has been extracted in the checkout
- **THEN** `git status` shows no new untracked or modified files from either
