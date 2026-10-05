# keccak-coprocessor Specification

## Purpose

Defines the Keccak instruction-set extension that CVA6 executes through its CV-X-IF coprocessor interface: the instructions' encodings and architectural behaviour, the coprocessor-held Keccak state, and the constraints under which software may rely on it, with no change to CVA6's own RTL.

## Requirements

### Requirement: Instruction encodings

The extension SHALL define five instructions. All use the RISC-V `custom-1` major opcode (`0101011`) in R-type format with `funct7 = 0000000`, and are distinguished by `funct3`. (`custom-0` is not usable: the pinned CVA6 decodes the whole `custom-0` opcode as PULP's `FENCE.T`, so no `custom-0` word ever reaches the coprocessor.)

| Mnemonic | `funct3` | Operands used | Writes `rd` |
|---|---|---|---|
| `kclr`  | `000` | none | no |
| `kxor`  | `001` | `rs1` = data, `rs2` = lane index | no |
| `krd`   | `010` | `rs2` = lane index | yes |
| `shatr` | `011` | `rs1` = round index | no |
| `kperm` | `100` | none | no |

Any `custom-1` encoding not listed in the table, meaning another `funct3` or a non-zero `funct7`, SHALL raise an illegal-instruction exception (`mcause` = 2) and SHALL leave the Keccak state unchanged. An instruction that does not write `rd` SHALL have `rd = x0` in its encoding. A non-writing instruction with any other `rd` field SHALL raise an illegal-instruction exception, SHALL leave the Keccak state unchanged, and SHALL leave every integer register unchanged. This rule exists because the pinned CVA6 forwards a non-writing offloaded instruction's result to an immediately following reader of its `rd` (see design D3), and requiring `rd = x0` makes that path unreachable.

#### Scenario: Unassigned funct3 is illegal

- **WHEN** software executes a `custom-1` R-type instruction with `funct3 = 101` and `funct7 = 0`
- **THEN** an illegal-instruction exception is taken with `mcause` = 2, and a subsequent `krd` of every lane returns the same values as before the instruction

#### Scenario: Non-zero funct7 is illegal

- **WHEN** software executes `kxor`'s encoding with `funct7 = 0000001`
- **THEN** an illegal-instruction exception is taken and the Keccak state is unchanged

#### Scenario: Non-writing instruction with a non-zero rd is illegal

- **WHEN** `kxor`'s encoding is executed with `rd = x5`, `x5` holding the value `V` beforehand, and the next instruction reads `x5`
- **THEN** an illegal-instruction exception is taken, the Keccak state is unchanged, and both that next instruction and every later reader of `x5` see `V`

### Requirement: Keccak state and lane addressing

The coprocessor SHALL hold one Keccak-f[1600] state of 25 64-bit lanes per hart, outside the integer register file. Lane index `i` SHALL address the lane at coordinates `x = i mod 5`, `y = i div 5`, using FIPS 202 lane ordering and byte order, so that the byte at state offset `8*i + k` is byte `k` (little-endian) of lane `i`. A lane index is the value of the source register, not an encoding field. A lane index of 25 or more SHALL raise an illegal-instruction exception and leave the state unchanged. The state's value after reset is unspecified, and software SHALL execute `kclr` before relying on it.

#### Scenario: Write then read back a lane

- **WHEN** software executes `kclr`, then `kxor` with data `0x0123456789ABCDEF` and lane index 7, then `krd` of lane 7
- **THEN** `rd` receives `0x0123456789ABCDEF`, and `krd` of every other lane returns 0

#### Scenario: Out-of-range lane index

- **WHEN** `krd` or `kxor` is executed with a lane-index register value of 25
- **THEN** an illegal-instruction exception is taken, `rd` is not written, and the state is unchanged

### Requirement: Absorb, squeeze and clear semantics

`kclr` SHALL set all 25 lanes to zero. `kxor` SHALL replace lane `i` with its XOR with the full 64-bit value of `rs1`. `krd` SHALL write the 64-bit value of lane `i` to `rd`. These three instructions SHALL be sufficient to save and restore the entire state from software. For a state `S` read out with 25 `krd`, then `kclr` and 25 `kxor` of the saved values reproduce `S` exactly.

#### Scenario: Software save and restore

- **WHEN** software reads all 25 lanes with `krd`, executes `kperm`, then executes `kclr` followed by 25 `kxor` of the saved values
- **THEN** a further 25 `krd` return exactly the originally saved values

### Requirement: Permutation semantics

`shatr` SHALL apply exactly one round of Keccak-f[1600] (θ, ρ, π, χ, ι) to the state, using the FIPS 202 round constant for the round index in `rs1`. Valid round indices are 0 to 23. Any other value SHALL raise an illegal-instruction exception and leave the state unchanged. `kperm` SHALL apply the full 24-round Keccak-f[1600] permutation. Executing `shatr` with round indices 0, 1, …, 23 in order SHALL produce the same state as one `kperm`.

#### Scenario: Round-by-round equals full permutation

- **WHEN** a state is loaded, copied, and one copy is transformed by `shatr` with round indices 0 through 23 while the other is transformed by one `kperm`
- **THEN** all 25 lanes of the two results are equal, and equal to a reference Keccak-f[1600] software implementation applied to the same input

#### Scenario: Zero-state permutation matches the known answer

- **WHEN** software executes `kclr` then `kperm`, then reads lane 0 with `krd`
- **THEN** `rd` receives `0xF1258F7940E1DDE7`, the first lane of Keccak-f[1600] applied to the all-zero state

#### Scenario: Round index out of range

- **WHEN** `shatr` is executed with `rs1` = 24
- **THEN** an illegal-instruction exception is taken and the state is unchanged

### Requirement: Program order of coprocessor instructions

Coprocessor instructions SHALL take effect on the Keccak state in program order. An instruction SHALL observe the effects of every earlier coprocessor instruction, including a multi-cycle `kperm` that has not finished when the later instruction is decoded. No instruction SHALL observe the effect of a later one. Instructions that do not use the coprocessor SHALL execute with their normal semantics and SHALL NOT be affected by coprocessor activity, except for being stalled.

#### Scenario: Read immediately after a permutation

- **WHEN** `kperm` is followed directly by `krd` of lane 0, with no intervening instruction
- **THEN** `krd` returns lane 0 of the permuted state, not of the state before `kperm`

### Requirement: Integration through CV-X-IF without core RTL changes

The extension SHALL be executed by a coprocessor connected to CVA6 through the core's existing CV-X-IF port. CVA6 SHALL be enabled for it only through its configuration parameters, and its RTL and its dependency pin SHALL be unchanged. Enabling CV-X-IF SHALL NOT change the architectural behaviour of any instruction outside the extension. In particular, an encoding that is illegal in the base configuration and not claimed by the coprocessor SHALL still raise an illegal-instruction exception with the same `mcause`, and `mtval` SHALL hold the same value as in the base configuration.

#### Scenario: Genuinely illegal instruction still traps

- **WHEN** software executes the all-zero instruction word `0x00000000` with CV-X-IF enabled
- **THEN** an illegal-instruction exception is taken with `mcause` = 2, exactly as with CV-X-IF disabled

#### Scenario: Existing tests unaffected

- **WHEN** the Cheshire tests that pass on the Xcelium lane before this change (`helloworld`, `dma_2d`, `spm_uncached`) run on the SoC with the coprocessor connected
- **THEN** each still reports `PASS`

#### Scenario: Core sources unchanged

- **WHEN** the CVA6 source files compiled into the SoC are compared with those of the pinned CVA6 revision
- **THEN** they are identical except for the configuration package values the build already rewrites

### Requirement: Documented operating constraint for interrupted sequences

Because CVA6's CV-X-IF implementation provides no kill signal for an instruction already offloaded, the extension's guarantees SHALL be stated as holding only for code that executes coprocessor instructions with interrupts disabled and with no older instruction able to raise a synchronous exception after a coprocessor instruction has been offloaded. The project SHALL document this constraint. It SHALL also provide a directed test that shows what happens when the constraint is violated, rather than leaving that behaviour undetermined. All correctness and benchmark programs in this change SHALL run under the constraint.

#### Scenario: Constraint is characterised, not assumed

- **WHEN** the directed test runs a coprocessor sequence and a timer interrupt is taken in the middle of it
- **THEN** the test's output records whether any coprocessor instruction was applied more than once or applied while flushed, and that result is stated in the project's documentation of the constraint

#### Scenario: Benchmarks run under the constraint

- **WHEN** any known-answer or benchmark program in this change executes coprocessor instructions
- **THEN** machine interrupts are disabled for the duration of each coprocessor sequence
