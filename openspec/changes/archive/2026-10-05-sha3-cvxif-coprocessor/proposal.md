# SHA-3 (Keccak) instructions via a CV-X-IF coprocessor, with an MMIO accelerator as the comparison arm

## Why

The thesis needs an ISA extension whose PPA delta is large enough for the open SG13G2 flow to resolve, and whose speedup is large enough to be worth a headline. SHA-2/`Zknh` fails both tests: its instructions replace a few rotate/XOR ops (~1.4–2.3× on SHA-256), and the hardware is ~2.5k gates with no flip-flops. Phase 14 measured ±0.04 % whole-SoC cell drift from ABC alone, and a `Zknh` adder is about that size. SHA-3 is the opposite case. A Keccak round is expensive in software, especially here because `cv64a6_imafdcsclic_sv39` has `RVB = 0`, so there is no `rori`. The unit needs ~1,600 state flip-flops, which is clearly measurable. arXiv:2508.20653 (`shatr`, one Keccak-f round per instruction) reports 8.02–46.31× on an FPGA CVA6 but publishes no encoding, no state-transfer mechanism and no RTL. Building the same instruction behind CVA6's CV-X-IF, with the core RTL unmodified, and measuring it on a fabricable PDK is the contribution. The paper never asks the question a reviewer will ask: *why not a memory-mapped accelerator?* So the change also builds one and reports the message length at which each approach wins.

This resolves the open "CV-X-IF vs `Zknh`" decision (`docs/infra-plan.md`, "ISA integration"; Phase 7) in favour of CV-X-IF with SHA-3.

**Flow stages touched:** RTL (new `hw/coproc/` blocks; Cheshire fork port and config field; CVA6 configuration only), sim (block unit testbenches; SoC tests on the Xcelium lane), synth (keep-hierarchy selectors; standalone block synthesis), backend (measurement only: timing/power read from the existing P&R lane, with no flow changes), CI (`sim-unit` and `synth-coproc` graduate from stubs), sw (new project-local test/benchmark programs and vendored baselines).

## What Changes

- **New instruction family on the `custom-1` opcode** (`custom-0` is `FENCE.T` in the pinned CVA6), executed by a new CV-X-IF coprocessor `hw/coproc/` that holds the 1600-bit Keccak state:
  - `kclr`: zero the state.
  - `kxor`: XOR a 64-bit register into lane *i*. This is the absorb step.
  - `krd`: read lane *i* into `rd`. This is the squeeze step, and also how software saves the state.
  - `shatr`: one Keccak-f[1600] round. This keeps the paper's semantics.
  - `kperm`: the full 24-round permutation, multi-cycle, with a synthesis-time rounds-per-cycle parameter.

  The family has five instructions. The single-instruction `shatr` alone cannot work on this core: the CV-X-IF port carries two 64-bit operands, returns one 64-bit result, and has no memory channel.
- **CVA6 configuration flip**: CVA6's `CvxifEn` config field is set through a new Cheshire config field, `Cva6CvxifEn = 1` in `hw/iguana_pkg.sv`. `IG_CVA6_PKG_PARAMS` cannot do it: Cheshire builds the core's `cva6_cfg_t` itself and hard-codes `CvxifEn : 0`. The CVA6 RTL and the CVA6 pin stay unchanged. A side effect: illegal instructions now reach the illegal-instruction trap through the coprocessor's reject path, so that path is regression-tested.
- **Cheshire fork `v0.3.1-newt.2`**: exposes core 0's `cvxif_req_o`/`cvxif_resp_i` (currently tied off in `cheshire_soc.sv`) as `cheshire_soc` ports, and adds the `cheshire_cfg_t` field `Cva6CvxifEn` (default 0) that drives CVA6's `CvxifEn`. `iguana_soc` connects the ports to the coprocessor.
- **Comparison arm: a Keccak MMIO accelerator** on a Cheshire external AXI subordinate port (`AxiExtNumSlv`, currently 0). It has control/status registers, an absorb window and digest registers. It is driven either by CPU stores or by Cheshire's existing iDMA.
- **Software** under a new project `sw/` tree, built against Cheshire's runtime:
  - `.insn` wrappers for the new instructions;
  - SHA3-224/256/384/512 on the ISE, on the MMIO accelerator, and on two pinned software baselines (the RISC-V reference SHA-3 and XKCP);
  - NIST known-answer tests;
  - `mcycle`/`minstret`-instrumented benchmarks.
- **Evaluation**, adapted from the paper's method to this flow:
  - NIST vectors and the same two software baselines;
  - RTL-simulated cycle counts as a per-block linear fit, which replaces gem5;
  - Yosys/OpenROAD area, timing and activity-annotated power, which replace FPGA LUT/FF counts;
  - a rounds-per-cycle sweep;
  - the measured ISE-vs-MMIO crossover message length.
- **Docs**: record the decision in the thesis plan and the infra plan, and correct the plan's "~10 % area / 42–44× Zkne/Zknh" anchor. Those are AES (`Zkne`) figures, not SHA figures. Also update the "decision pending" wording in `AGENTS.md`, `openspec/config.yaml` context and `README.md`.

Not **BREAKING** for any existing flow. The default SoC changes (CV-X-IF enabled, two new blocks), so cell count, area and the illegal-instruction path all move. That is the measured delta. `synth-baseline.json` stays the stock-SoC reference and is not reseeded.

## Capabilities

### New Capabilities

- `keccak-coprocessor`: the ISE's architectural behaviour (encodings, state, lane indexing, exceptions, ordering) and how it is integrated through CV-X-IF without core RTL changes, including the documented speculation/interrupt operating constraint.
- `keccak-mmio-accelerator`: the memory-mapped Keccak accelerator's register map, CPU-driven and DMA-driven operation, and its integration on the external AXI port.
- `sha3-evaluation`: how correctness, cycle counts, PPA and the ISE/MMIO crossover are measured and reported, so that numbers are reproducible and comparable with arXiv:2508.20653.

### Modified Capabilities

- `rtl-dependencies`: the Cheshire pin moves from `v0.3.1-newt.1` to `v0.3.1-newt.2`, the fork tag that exposes the CV-X-IF port.
- `ci-pipeline`: `sim-unit` and `synth-coproc` graduate from stubs to real, gating checks, as the "stub graduates only via an explicit follow-up" requirement prescribes.

## Impact

- **Code:**
  - new `hw/coproc/` (coprocessor, MMIO accelerator, shared round datapath, unit testbenches);
  - `hw/iguana_soc.sv` and `hw/iguana_pkg.sv` (instantiation, `Cva6CvxifEn`, `AxiExt*` config);
  - `Bender.yml`/`Bender.lock`;
  - `target/ihp13/yosys/project-synth.mk` (two keep-hierarchy selectors);
  - possibly `target/ihp13/pickle/patch/svase/svase.sed`, whose regbus/AXI port-count rules key on the xbar shape;
  - `target/xcelium/` (a coprocessor-scoped VCD mode);
  - new `sw/`;
  - `.github/workflows/ci.yml`.
- **Dependencies:** a new `wortexx/cheshire` tag. Vendored, license-checked copies of the riscv-crypto SHA-3 reference and XKCP Keccak-p[1600] sources, and of the NIST SHA-3 test vectors.
- **Measurement risk:**
  - The P&R lane cannot currently detail-route, and `cts` timed out on its last real run (infra-plan Phase 11). SoC timing and power may have to come from post-placement or post-GRT STA, or only from block-level analysis. Which stage is quoted is decided in design.
  - The Xcelium VM runs ~5k cycles/s, so long-message figures are extrapolated from per-block fits, as the paper's own table would otherwise require ~10¹⁰ simulated cycles.
- **Schedule:** this is larger than a `Zknh`-only scope. The tasks are ordered so the ISE path (correctness, cycles, PPA) completes on its own before the MMIO arm and the crossover begin.
- **Out of scope:** SHAKE/XOF modes, OS/Linux context-switch support (state is software-saveable via `krd`/`kxor`, but no kernel integration), side-channel masking, any CVA6 RTL change or fork, and closing timing on the SoC.
