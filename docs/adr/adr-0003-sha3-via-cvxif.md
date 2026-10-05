---
title: "ADR-0003: SHA-3 (Keccak) instructions in a CV-X-IF coprocessor, with an MMIO accelerator as the comparison arm"
status: "Accepted"
date: "2026-10-01"
authors: "Sergii Bidnyi (thesis author)"
tags: ["architecture", "decision", "isa", "cva6", "cvxif", "sha3", "keccak", "thesis-scope"]
supersedes: ""
superseded_by: ""
---

## Status

**Accepted** on 2026-10-01. It resolves the "ISA integration — open decision" in
[`docs/infra-plan.md`](../infra-plan.md) and Phase 7's decision item: mechanism
1 (CV-X-IF) vs 2 (`Zknh`), and which hashes. The work is carried out by the
OpenSpec change
[`sha3-cvxif-coprocessor`](../../openspec/changes/archive/2026-10-05-sha3-cvxif-coprocessor/), whose
`design.md` D1 records the same decision in planning form. It is built on
[ADR-0002](adr-0002-bender-pinned-forks-not-patches.md): the one dependency change it
needs goes into the Cheshire fork.

An earlier draft numbered ADR-0003 proposed the `Zknh` encodings executed by a
CV-X-IF coprocessor. It was withdrawn on the same day, before it was
committed, and this record replaces it. That option appears below as ALT-002.

## Context

The thesis adds a cryptographic ISA extension to CVA6 inside Basilisk and
reports PPA figures from a real IHP SG13G2 synthesis and P&R flow, not FPGA
estimates. [`docs/custom-isa-extension.md`](../custom-isa-extension.md) left
two mechanisms open: a CV-X-IF coprocessor with custom opcodes, or the ratified
`Zknh` extension (SHA-2) in the core pipeline.

**The measurement has to resolve the extension.** The contribution is a
physically realistic PPA delta on an open 130 nm flow. That only works if the
extension's delta stands clear of the flow's own noise:

- The whole SoC is 735,953 cells, 17.77 mm² and 89,499 DFFs
  (`target/ihp13/yosys/synth-baseline.json`).
- ABC mapping alone moves untouched modules by about ±0.04 % of cells
  (infra-plan Phase 14).
- A `Zknh` datapath is about 2.5k gates of rotate/XOR and has **no flip-flops**:
  - its area delta sits at the noise floor;
  - its timing and power deltas cannot be told apart from placement perturbation.
- A Keccak-f[1600] unit holds 1,600 state flip-flops and a full round of logic.
  Measured standalone (task 2.5): `keccak_cvxif` at one round per cycle is
  19,771 cells, ~0.267 mm² (~1.5 % of the SoC) and 1,681 DFFs, with +8.99 ns of
  slack at the 11 ns system clock.

**The speedup has to be worth reporting.** `Zknh` replaces the SHA-2 σ/Σ
functions, which are three rotates and two XORs each. Estimated against this
core's own software baseline:

- **SHA-256 with `Zknh`:** about 1.4–2.3×. The low end applies if the baseline
  had bitmanip rotates; the high end is without them, since `RVB = 0` in
  `cv64a6_imafdcsclic_sv39`. The literature reports ~1.3–2× for SHA-2.
- **SHA-3:** a Keccak-f[1600] round is expensive in software, especially without
  `rori`.
- **arXiv:2508.20653** reports 8.02× and 46.31× for a single-round `shatr`
  instruction on an FPGA CVA6. That paper publishes no encoding, no
  state-transfer mechanism and no RTL. Building "the same instruction" therefore
  means re-deriving it, which is itself a contribution.
- **Correction to the thesis plan:** the plan's "~10 % area / 42–44×" anchor is
  AES (`Zkne`), not SHA.

**The closest prior work occupies the in-pipeline space.** CryptRISC
(arXiv:2602.20285) adds the 64-bit scalar crypto extensions to CVA6 as an
execute-stage functional unit, with FPGA-only numbers. An in-core `Zknh`
implementation would be a strict subset of it, distinguished only by the PDK.

**What the pinned sources allow.** Checked in CVA6 `9338c2ca` (`pulp-v1.0.0`) and
Cheshire `v0.3.1`:

- **CV-X-IF exists and works.** It is the pre-1.0 interface: two 64-bit source
  operands, one 64-bit result, and an `x_mem` channel that the core never drives.
  The bring-up in change tasks 1.x showed the offload handshake working on the
  Xcelium lane.
- **It is reached through Cheshire's config, not the CVA6 package.** Cheshire
  builds the core's `cva6_cfg_t` itself and hard-codes `CvxifEn : 0`. So
  `CvxifEn` needs a small Cheshire fork change (`v0.3.1-newt.2`); the
  `iguana.mk` package rewrite cannot set it.
- **`custom-0` decodes as PULP's `FENCE.T`**, so the custom ISE has to use
  `custom-1`.
- **A non-writing offload with `rd ≠ x0` forwards its result** to an immediately
  dependent reader. The ISE therefore requires `rd = x0` on its non-writing
  instructions.
- **No offloaded instruction is ever killed.** An interrupt, or a late exception
  from an older instruction, can re-execute an offloaded instruction that has
  already changed coprocessor state.

**Why a memory-mapped accelerator belongs in the evaluation.** A reviewer will
ask "why an ISE and not an accelerator?". The CV-X-IF port moves 128 bits in and
64 bits out per instruction and cannot fetch from memory. A memory-mapped Keccak
engine fed by Cheshire's iDMA has no such bottleneck but pays a per-call bus
overhead. Which one wins depends on message length, and the crossover is a
measurable result that neither the paper nor CryptRISC reports.

## Decision

**Implement SHA-3 (Keccak-f[1600]) instructions in a CV-X-IF coprocessor, with
CVA6's RTL and pin unchanged. Build a memory-mapped Keccak accelerator in the
same SoC as a comparison arm, and report the measured ISE-vs-MMIO crossover
message length. `Zknh` is not implemented.**

- **Instruction set.** Five R-type instructions on `custom-1` (`0x2B`) with
  `funct7 = 0`:
  - `kclr`: clear the state.
  - `kxor`: absorb a 64-bit value into a lane.
  - `krd`: read a lane, which is also how software saves the state.
  - `shatr`: one Keccak-f round, the paper's semantics.
  - `kperm`: the full 24-round permutation, multi-cycle, with a synthesis-time
    rounds-per-cycle knob of 1, 2, 3, 4 or 6.

  The paper's single `shatr` cannot work alone on this core: the port is too
  narrow and has no memory channel. Non-writing instructions require `rd = x0`.
  The contract is spec `keccak-coprocessor`.
- **Mechanism.**
  - A coprocessor under `hw/coproc/`, instantiated in `iguana_soc` on core 0's
    CV-X-IF port.
  - The port is exposed, and enabled through the `Cva6CvxifEn` config field, by
    Cheshire fork tag `v0.3.1-newt.2`.
  - No CVA6 fork.
- **Comparison arm.** A Keccak accelerator on Cheshire's external AXI
  subordinate port, in the external non-cached region. It is driven by CPU
  stores or by Cheshire's iDMA, and shares the round datapath with the
  coprocessor so the comparison isolates the integration path.
- **Toolchain.** `.insn r` intrinsics (`sw/include/keccak_ise.h`). No compiler or
  assembler changes.
- **Evaluation.** The paper's method, adapted to this flow (spec
  `sha3-evaluation`):
  - Correctness: NIST CAVP SHA-3 known-answer vectors.
  - Software baselines, three of them:
    - the riscv-crypto reference SHA-3, the paper's first baseline;
    - XKCP `ref-64bits`, the paper's "Keccak Team reference";
    - XKCP `opt64`, a fair optimised baseline.
  - Cycle counts from RTL simulation, as per-block linear fits, instead of gem5.
  - Area, timing and activity-annotated power from Yosys/OpenSTA/OpenROAD,
    instead of FPGA LUT/FF counts.
  - A rounds-per-cycle sweep.
  - The ISE-vs-MMIO crossover.
- **Operating constraint.** Coprocessor sequences run with interrupts disabled.
  The re-execution hazard is characterised by a directed test and documented
  (`hw/coproc/README.md`), not fixed in the core.
- **Excluded from scope:**
  - `Zknh` and SHA-2 instructions;
  - SHAKE/XOF modes;
  - OS context-switch support (the state is software-saveable, with no kernel
    integration);
  - power side-channel masking or leakage verification;
  - any CVA6 RTL change;
  - timing closure of the SoC.

## Consequences

### Positive

- **POS-001**: A PPA delta well above the flow's resolution. The block's own area
  and timing come straight from its kept-hierarchy instance and from standalone
  block synthesis.
- **POS-002**: A large, reportable speedup on a workload where an ISE plausibly
  pays off, directly comparable in form to arXiv:2508.20653's Table I.
- **POS-003**: A differentiated contribution:
  - the same instruction semantics as an FPGA-only paper;
  - integrated non-invasively through CV-X-IF;
  - measured on a fabricable PDK;
  - with a rounds-per-cycle design-space sweep and an ISE-vs-MMIO crossover that
    neither the paper nor CryptRISC has.
- **POS-004**: CVA6 stays unmodified. A future CVA6 bump affects only the
  coprocessor interface, not a carried core patch.
- **POS-005**: Facts about this CVA6 release are found and documented that matter
  to anyone using its CV-X-IF: `custom-0` is `FENCE.T`, results are forwarded on
  non-writing offloads, and nothing is ever killed.

### Negative

- **NEG-001**: No ratified ISA. There is no `riscv-arch-test` suite and no compiler
  support, and software must use the intrinsics. Correctness rests on the NIST
  vectors, an independent C++ reference model, and block testbenches.
- **NEG-002**: The 2×64-in / 64-out port bounds absorb throughput, since every
  rate lane costs a load plus a `kxor`. That bottleneck is the reason for the
  MMIO arm.
- **NEG-003**: The interrupt and late-exception re-execution hazard is inherent
  to this CV-X-IF release. The extension is safe only under the documented
  operating constraint.
- **NEG-004**: The no-`rori` software baseline (`RVB = 0`) inflates every speedup.
  The evaluation must report how much of the baselines' work is synthesizing
  rotates.
- **NEG-005**: A larger scope than a `Zknh`-only thesis. The task order lets the
  ISE arm complete before the MMIO arm starts, so a schedule cut drops the
  comparison, not the core result.
- **NEG-006**: The Cheshire fork grows by one patch, with the maintenance cost
  ADR-0002 accepts.

## Alternatives Considered

### `Zknh` in the CVA6 pipeline (the CryptRISC approach)

- **ALT-001**: **Description**: Add the eight RV64 `Zknh` instructions to the
  CVA6 decoder and ALU in a CVA6 fork, single-cycle with forwarding.
- **ALT-001**: **Rejection Reason**: It gives a ~1.4–2.3× speedup, and its
  hardware delta sits at the flow's noise floor, so the thesis's central
  measurement would have nothing to measure. It also needs a core fork, and it
  is a subset of CryptRISC.

### `Zknh` encodings executed by a CV-X-IF coprocessor

- **ALT-002**: **Description**: Keep the ratified encodings. They are illegal
  OP-IMM words in this configuration, so CVA6 offloads them. Execute them in a
  coprocessor without touching the core. This was the withdrawn draft ADR-0003.
- **ALT-002**: **Rejection Reason**: It keeps the non-invasive property and gets
  full toolchain support. But it inherits ALT-001's magnitude problem unchanged,
  and adds CV-X-IF round-trip latency to instructions that are a few gates deep.

### SHA-3 in the CVA6 pipeline (the paper's microarchitecture)

- **ALT-003**: **Description**: Put a Keccak execution unit with internal state
  inside CVA6's execute stage, as arXiv:2508.20653 does.
- **ALT-003**: **Rejection Reason**: It is the closest reproduction of the paper,
  but it needs a core fork and invents the same ISA anyway, because the paper
  publishes none. It gives up the non-invasive integration that distinguishes
  this work.

### Memory-mapped accelerator only

- **ALT-004**: **Description**: A fixed-function Keccak engine on the AXI bus,
  with no ISA change.
- **ALT-004**: **Rejection Reason**: It is not an ISA extension, so it does not
  answer the thesis question. It is kept, as the comparison arm.

### Fix the CV-X-IF kill path in CVA6

- **ALT-005**: **Description**: Drive `x_commit_kill` from the scoreboard in a
  CVA6 fork, so a flushed offload can be discarded.
- **ALT-005**: **Rejection Reason**: It removes the re-execution hazard but
  breaks the "no core RTL change" property that the contribution rests on. It is
  recorded as future work.

## Implementation Notes

- **IMP-001**: Executed by OpenSpec change `sha3-cvxif-coprocessor`. Its specs
  (`keccak-coprocessor`, `keccak-mmio-accelerator`, `sha3-evaluation`) are the
  behavioural contract. `tasks.md` tracks progress.
- **IMP-002**: The CVA6 facts above were all found by the change's CV-X-IF
  smoke test on the Xcelium lane. They must be rechecked on every CVA6 pin move,
  which is the same rule as ADR-0002's "check that every patch still matches":
  - the `custom-0` decode;
  - the forwarding on non-writing offloads;
  - the missing kill.
- **IMP-003**: Which P&R stage the thesis quotes SoC timing and power from is set
  by the change's evaluation spec. Every number states its stage, because the
  P&R lane cannot detail-route today (infra-plan Phase 11).
- **IMP-004**: Reversal conditions:
  - If the CV-X-IF arm cannot be made correct under the operating constraint,
    fall back to ALT-003 (in-core), with the same instruction set, tests and
    evaluation.
  - If the schedule forces a cut, drop the MMIO arm, not the ISE arm.

  Either needs a superseding ADR.

## References

- **REF-001**: "Microarchitecture Design and Benchmarking of Custom SHA-3
  Instruction for RISC-V", arXiv:2508.20653 (2025): the `shatr` instruction and
  the benchmarking method this work adapts.
- **REF-002**: A. Srivastava, M. Porwal, K. Basu, "CryptRISC", arXiv:2602.20285
  (2026): in-pipeline scalar crypto on CVA6.
- **REF-003**: NIST FIPS 202, *SHA-3 Standard*; NIST CAVP SHA-3 byte test vectors.
- **REF-004**: RISC-V Scalar Cryptography Extensions v1.0.1 (`Zknh`).
- **REF-005**: [`docs/custom-isa-extension.md`](../custom-isa-extension.md) (the
  thesis plan) and [`docs/infra-plan.md`](../infra-plan.md) ("ISA integration",
  Phases 7, 11, 14 and 15).
- **REF-006**:
  [`openspec/changes/archive/2026-10-05-sha3-cvxif-coprocessor/`](../../openspec/changes/archive/2026-10-05-sha3-cvxif-coprocessor/)
  (design D1–D9) and [`hw/coproc/README.md`](../../hw/coproc/README.md).
- **REF-007**: [ADR-0002](adr-0002-bender-pinned-forks-not-patches.md): the
  Cheshire fork that carries the CV-X-IF port and `Cva6CvxifEn`.
- **REF-008**: CVA6 `9338c2ca` `core/decoder.sv` (`custom-0` → `FENCE.T`; CV-X-IF
  offload), `core/scoreboard.sv` (forwarding), `core/cvxif_fu.sv` and
  `core/issue_read_operands.sv` (no kill); Cheshire `hw/cheshire_pkg.sv`
  (`gen_cva6_cfg`).
