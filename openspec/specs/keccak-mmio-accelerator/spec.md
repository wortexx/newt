# keccak-mmio-accelerator Specification

## Purpose

Defines a memory-mapped Keccak accelerator on the SoC's external AXI port. It is the non-ISA comparison arm for the Keccak instruction-set extension. It computes the same SHA-3 functions with no change to the instruction set, and can be driven by CPU stores or by the SoC's DMA engine.

## Requirements

### Requirement: Address window and register interface

The accelerator SHALL occupy one contiguous region of the physical address map, reached through Cheshire's external AXI subordinate port. The region SHALL be disjoint from every existing region, and its base address and register layout SHALL be documented in the project. It SHALL expose at least the following:

- a control register: clear state, start permutation, select rate;
- a status register: busy and done flags;
- an absorb window: a 64-bit-aligned write here XORs the written data into the state lane given by the word's offset;
- a digest window: a read here returns state lanes.

Accesses outside the documented registers SHALL complete with an AXI error response and SHALL NOT change the accelerator's state.

#### Scenario: Region is reachable and does not alias

- **WHEN** software reads the status register at the documented address on the SoC
- **THEN** the read completes with an OKAY response and reports not-busy after reset, and no other device's registers change

#### Scenario: Undefined offset

- **WHEN** software writes to an offset inside the region that maps to no documented register
- **THEN** the access completes with an AXI error response and a subsequent digest read is unaffected

### Requirement: Functional equivalence with the instruction extension

For any message and any of SHA3-224, SHA3-256, SHA3-384 and SHA3-512, a digest computed with the accelerator SHALL be bit-identical to the digest computed with the Keccak instruction extension and to the FIPS 202 reference. The accelerator's permutation SHALL be Keccak-f[1600] with 24 rounds.

#### Scenario: Same digest three ways

- **WHEN** one NIST SHA3-256 known-answer message is hashed with the accelerator, with the instruction extension and with the software baseline
- **THEN** all three digests equal the NIST expected digest

### Requirement: CPU-driven and DMA-driven operation

The accelerator SHALL produce correct digests both when the message is written into the absorb window by CPU stores and when Cheshire's existing DMA engine copies it from memory into the absorb window. Software SHALL detect completion of a permutation by polling the status register. The accelerator SHALL NOT require an interrupt line.

#### Scenario: DMA-fed digest

- **WHEN** software programs the DMA engine to copy one rate-sized block from memory into the absorb window, waits for the DMA to complete, starts a permutation and polls until done
- **THEN** the digest read back equals the reference digest for that block

#### Scenario: Write while busy

- **WHEN** software writes to the absorb window while the status register reports busy
- **THEN** the write does not corrupt the permutation in progress: either it is held until the permutation completes, or it returns an AXI error response, with the documented behaviour applied consistently

### Requirement: Coexistence with the instruction extension

The accelerator and the CV-X-IF coprocessor SHALL be present in the same SoC build, each with its own independent Keccak state. Using one SHALL NOT change the state or results of the other.

#### Scenario: Independent states

- **WHEN** software loads a state into the coprocessor, then performs a full hash on the accelerator, then reads the coprocessor's lanes
- **THEN** the coprocessor lanes are unchanged
