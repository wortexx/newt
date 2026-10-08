# sha3-evaluation Specification

## Purpose

Defines how the SHA-3 instruction extension and its MMIO comparison arm are verified and measured: correctness, cycle counts, area, timing, power, and the ISE/MMIO crossover. The results must be reproducible from the repository and comparable with arXiv:2508.20653's benchmarking method.

## Requirements

### Requirement: Known-answer correctness gate

The project SHALL provide known-answer test programs that hash NIST SHA-3 test-vector messages for SHA3-224, SHA3-256, SHA3-384 and SHA3-512. They SHALL use each implementation under test: the instruction extension, the MMIO accelerator, and each software baseline. Each program SHALL compare every computed digest with the expected value, and SHALL exit non-zero on the first mismatch, naming the variant, implementation and vector. The vector set SHALL include the empty message, at least one message whose length is not a multiple of 8 bytes, and messages exactly at, one byte below and one byte above each variant's rate. A subset of the NIST long-message vectors SHALL also be included, sized so the full set completes on the Xcelium lane within its configured timeout.

#### Scenario: All implementations pass the vectors

- **WHEN** the known-answer programs run on the Xcelium lane against the SoC with the coprocessor and accelerator connected
- **THEN** every program reports `PASS`

#### Scenario: A wrong digest fails loudly

- **WHEN** an implementation produces a digest that differs from the expected value for any vector
- **THEN** the program exits non-zero, its UART log names the variant, implementation and vector index, and the lane reports `FAIL`

### Requirement: Pinned, reproducible software baselines

The software baselines SHALL be the RISC-V reference SHA-3 implementation and the Keccak Team (XKCP) Keccak-p[1600] implementation, vendored at recorded upstream revisions with their licenses. Both SHALL be built with the same compiler, the same compiler version and the same optimization flags as the instruction-extension code. The flags and the target ISA string SHALL be recorded alongside every reported number. The report SHALL state that the target ISA lacks bit-manipulation rotate instructions, and SHALL give the share of baseline instructions spent synthesizing rotates, so that a reader can judge how much of the speedup comes from that absence.

#### Scenario: Baseline provenance is recorded

- **WHEN** a benchmark result table is produced
- **THEN** it lists, for each baseline, the upstream revision, the compiler version, the optimization flags and the `-march` string

### Requirement: Cycle and instruction counts from RTL simulation

Cycle and retired-instruction counts SHALL be measured on the RTL of the SoC, not on an architectural model. They SHALL be read from the `mcycle` and `minstret` counters immediately around the hashing call, with the counter-read overhead measured and subtracted. For each variant and implementation, counts SHALL be measured for at least four message lengths spanning 0 to at least 4 full blocks. Costs SHALL follow a split model: a one-block message (shorter than the rate) costs its measured value, and longer messages follow a linear model `cycles = a + b * blocks` fitted on the measurements with at least two blocks. The fit SHALL be reported with its residuals, and the measured one-block cost with its deviation from the fitted line. Any figure for longer messages, including figures matched to the paper's long inputs, SHALL be labelled as extrapolated from that fit.

#### Scenario: Per-block cost is reported with its fit quality

- **WHEN** the benchmark runs for SHA3-256 on the instruction extension
- **THEN** the results contain the measured cycles and instructions per message length, the fitted `a` and `b`, the largest residual as a percentage of the measured value, and the one-block cost with its deviation from the fitted line

#### Scenario: Extrapolated values are marked

- **WHEN** a speedup is reported for a message length longer than any measured length
- **THEN** that value is explicitly marked as extrapolated in the report

### Requirement: Speedups comparable to the reference paper

The report SHALL give, for each SHA-3 variant and for short and long inputs, the speedup of the instruction extension over each of the two software baselines, in the same form as arXiv:2508.20653 Table I and its averaged 8.02× and 46.31× figures. It SHALL give `shatr`-based and `kperm`-based figures separately. It SHALL state the differences in method: RTL simulation instead of gem5, an ASIC flow instead of FPGA, and CV-X-IF instead of in-pipeline execution.

#### Scenario: Paper-shaped speedup table

- **WHEN** the evaluation report is generated
- **THEN** it contains a table with rows for ISE-with-`shatr`, ISE-with-`kperm`, RISC-V reference baseline and XKCP baseline, columns for short and long inputs per variant, and the speedup ratios against each baseline

### Requirement: Isolated area of each new block

The area of the coprocessor and of the MMIO accelerator SHALL each be reported as its own hierarchical instance in the full-SoC synthesis report. The synthesis keep-hierarchy selectors for both instances SHALL each match exactly one instance. The whole-SoC change in cells, area and flip-flops against the checked-in stock-SoC baseline SHALL also be reported. That change SHALL be reported together with the known ABC mapping-noise band of untouched modules, so that the reported increase is not attributed to the blocks beyond what their own instances show.

#### Scenario: Block area appears as its own line

- **WHEN** the full-SoC synthesis report of the build with both blocks is inspected
- **THEN** the coprocessor and the accelerator each appear as a separate instance with their own cell count, area and flip-flop count

#### Scenario: A selector that matches nothing is a defect

- **WHEN** either keep-hierarchy selector resolves to zero instances in the synthesized design
- **THEN** the measurement is treated as invalid and is not reported

### Requirement: Rounds-per-cycle design-space sweep

The coprocessor's `kperm` rounds-per-cycle parameter SHALL be swept over every supported value. For each value, the report SHALL give the standalone block's area, flip-flop count and critical-path delay against the SoC's 11.0 ns system clock constraint, and `kperm`'s latency in cycles. The value used in the full-SoC build SHALL be justified from this sweep.

#### Scenario: Sweep table

- **WHEN** the sweep completes
- **THEN** the report contains one row per supported rounds-per-cycle value with area, flip-flops, critical-path delay, slack against 11.0 ns and `kperm` cycles, and names the value selected for the SoC build

### Requirement: Timing and power with a stated measurement stage

Every reported timing or power figure SHALL name the flow stage it was taken from: block synthesis, post-placement, post-CTS or post-global-route. It SHALL also name the operating corner. A figure taken at post-global-route SHALL also state whether post-route timing repair ran before it was taken, and if the repair was attempted but did not complete, why. An achieved clock period or frequency derived from a worst negative slack SHALL name the stage and the repair status of that slack, and SHALL NOT be presented as the SoC's maximum frequency when repair was skipped. Power for the coprocessor and the accelerator SHALL be computed from switching activity recorded while running a hashing workload on that block. Default activity assumptions SHALL NOT be used. Every energy-per-hash or energy-per-byte figure SHALL be derived from such activity-annotated power, combined with measured cycle counts and the stated clock frequency.

#### Scenario: Power figure carries its provenance

- **WHEN** a power or energy number appears in the report
- **THEN** the report states the flow stage, the corner, the workload that produced the activity, and that the activity was annotated rather than defaulted

#### Scenario: Unavailable stage is reported, not substituted silently

- **WHEN** the P&R lane cannot reach a stage that the report intended to quote from
- **THEN** the report names the stage that was actually used and the reason

#### Scenario: Global-route timing carries its repair status

- **WHEN** a WNS, TNS or achieved period taken at post-global-route appears in the report
- **THEN** the report states whether post-route timing repair ran, and the reference and coprocessor figures it compares were both taken with the same repair status

#### Scenario: Repair attempted but not completed

- **WHEN** post-route timing repair was attempted for a run and timed out or failed
- **THEN** the report quotes the post-global-route figure without repair, labels it as such, and names the repair attempt's outcome and its run

### Requirement: Measured ISE-versus-MMIO crossover

The report SHALL determine the message length at which the MMIO accelerator, in both its CPU-driven and DMA-driven modes, becomes faster in cycles than the instruction extension for SHA3-256, or show that no crossover occurs within the measured range. It SHALL obtain the crossover from the per-implementation linear fits. It SHALL support each crossover with at least one measured point on each side, not with extrapolation alone.

#### Scenario: Crossover is bracketed by measurements

- **WHEN** the crossover length for DMA-driven MMIO versus `kperm`-based ISE is reported
- **THEN** the report shows a measured message length below it where the ISE is faster and a measured length above it where the accelerator is faster

#### Scenario: No crossover found

- **WHEN** one implementation is faster at every measured length
- **THEN** the report states that no crossover was observed in the measured range and gives the fitted lengths at which one would occur, if any, labelled as extrapolated
