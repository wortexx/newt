# SHA-3 CV-X-IF coprocessor + MMIO comparison arm — design

## Context

See proposal.md — Why. The pinned sources (CVA6 `9338c2ca`, Cheshire `v0.3.1-newt.1`) set the constraints:

- **CV-X-IF as implemented in this CVA6** (`core/include/cvxif_pkg.sv`, `core/cvxif_fu.sv`):
  - `X_NUM_RS = NR_RGPR_PORTS = 2`. That is a `localparam` in `ariane_pkg.sv:78`, so there is no `rs3`.
  - Each instruction carries two 64-bit operands in and one 64-bit result out.
  - The `x_mem_*` channel is declared but never driven, so the coprocessor cannot access memory.
  - `cvxif_fu` asserts `x_commit_valid` together with issue and hard-wires `x_commit_kill = 0`.
  - `issue_read_operands.sv` (~l.390–412) clears only the not-yet-sent `cvxif_valid_q` on `flush_i`. An instruction already offloaded is never cancelled.
- **Decoder** (`decoder.sv:1393`): with `CvxifEn = 1`, every illegal instruction is offloaded. `rs1`/`rs2`/`rd` come from the R4-type fields, and `rs3` would be `instr[31:27]`. That field is unused at 2 ports, and `funct7 = 0` makes it `x0` anyway. A non-accepted offload becomes an illegal-instruction exception in `cvxif_fu`, with `tval` set when `TvalEn`.
- **Config — two paths, only one reaches the core**: `iguana.mk` rewrites `cv64a6_imafdcsclic_sv39_config_pkg.sv` through `IG_CVA6_PKG_PARAMS`. That affects only the *package-level* constants that `ariane_pkg`/`riscv_pkg` read, such as cache sizes, scoreboard entries and `XLEN`. The *struct-level* `cva6_cfg_t` fields, among them `CvxifEn`, `RVB` and `RVH`, come from Cheshire's own `gen_cva6_cfg()` (`cheshire_pkg.sv`), which hard-codes `CvxifEn : 0`, `RVB : 0` and `RVH : 1` and passes the struct as `cva6 #(.CVA6Cfg(...))`. That overrides the package default. Found during task 1.1. A side effect is recorded in the infra plan: `iguana.mk`'s `CVA6ConfigHExtEn=0` never reaches the core, so the hypervisor extension is on in the baseline.
- **Cheshire** ties the port off (`cheshire_soc.sv:625-626`: `.cvxif_req_o ( ), .cvxif_resp_i ( '0 )`). The `AxiExt*` external subordinate ports exist but are unused. `iguana_soc` passes `axi_ext_slv_req_o ( )` / `axi_ext_slv_rsp_i ( '0 )`.
- **Address map**:
  - Regs at `0x0300_0000`;
  - SPM at `0x1000_0000` (cached) and `0x1400_0000` (uncached), backed by a 64 KiB LLC;
  - hyperbus config at `0x4000_0000`;
  - DRAM above.
- **Software**: Cheshire builds with `-march=rv64gc_zifencei -mabi=lp64d -O2 … -flto`.
- **Pickle**: `svase.sed` hard-codes `RegOut.num_out` as `14`. Adding a *regbus* device would silently break it. An *AXI* device does not touch it.
- **Simulation**:
  - Xcelium is the only SoC lane that passes. It runs ~5k simulated cycles/s on the restricted VM, and its `WAVES=vcd` mode currently probes only debug paths.
  - SoC-level Verilator does not yet pass, but Verilator on standalone blocks is unaffected.
- **P&R**: the lane cannot detail-route. Its latest real run timed out in `cts` (infra-plan Phase 11).

## Goals / Non-Goals

**Goals:**

- Five-instruction Keccak ISE behind CV-X-IF with **zero CVA6 RTL change**, plus a functionally identical MMIO accelerator in the same SoC build, both sharing one round datapath so the comparison isolates the integration path, not the round logic.
- Every reported number regenerable from the repo by named make targets and one evaluation script, with provenance (flow stage, corner, flags, revisions) attached.
- The ISE path (correctness → cycles → PPA) is independently complete before the MMIO arm starts, so a schedule cut drops the comparison, not the core result.

**Non-Goals:**

- Fixing CV-X-IF's missing kill/commit in CVA6 (would need a core fork; see D5).
- SHAKE128/256, cSHAKE, KangarooTwelve; multi-hart sharing of the coprocessor (Cheshire is built with one core here).
- Linux driver / context-switch integration; side-channel hardening.
- Timing closure of the SoC, or any P&R flow change made to get a number.

## Decisions

### D1 — SHA-3 over CV-X-IF (resolves the pending ISA decision)

Recorded from the explore session. The full rationale is in proposal.md. Alternatives:

- **`Zknh` in-core.** The speedup is ~1.4–2.3×, the PPA delta is at the flow's noise level, and it needs a CVA6 fork. It would also be a subset of CryptRISC.
- **`Zknh` encodings over CV-X-IF.** Viable, because the encodings are illegal OP-IMM here and get offloaded. It has the same magnitude problem.
- **SHA-3 in-core**, which is the paper's microarchitecture. It needs a fork and loses the non-invasive framing.
- **MMIO only.** No ISA contribution. That arm is kept here as the comparison.

Logged as [ADR-0003](../../../docs/adr/adr-0003-sha3-via-cvxif.md) ("SHA-3 (Keccak) instructions in a CV-X-IF coprocessor, with an MMIO accelerator as the comparison arm"). An earlier draft ADR-0003 proposing `Zknh` over CV-X-IF was withdrawn before being committed; that option is the ADR's ALT-002.

### D2 — Five instructions, lane index in a register, `custom-1`

`shatr` alone cannot work on this core. The state is 1,600 bits, but the port moves 128 bits in and 64 bits out, and the coprocessor cannot fetch from memory. Software therefore moves lanes:

- `kxor` absorbs a lane;
- `krd` squeezes a lane and also saves the state;
- `kclr` initializes.

`shatr` keeps the paper's per-round semantics, so its numbers compare directly with arXiv:2508.20653. `kperm` adds one-instruction permutation and carries the rounds-per-cycle knob, which is the design point the paper never explored.

- **Lane index in `rs2`, not the immediate.** R-type has no immediate, and I-type would lose `rs2`. A register index also lets a single unrolled absorb loop serve all four rates.
- **`custom-1` (`0b0101011`)** is reserved for vendor extensions at every XLEN, so it will never clash with a ratified extension. `custom-2`/`custom-3` are also custom on RV32/64, but RV128 reserves them. **`custom-0` was the original choice and is unusable here.** The pinned CVA6 decodes the entire `custom-0` opcode as PULP's `FENCE.T` (`decoder.sv:1381`), whatever `funct3`/`funct7` are, so such a word never becomes illegal and is never offloaded. This was found in task 1.7: `0x0000500B` executed silently as a fence. `custom-1` is proven to offload: the stock example coprocessor uses it, and the task 1.7 VCD shows its handshake.
- **Encodings** are fixed in `specs/keccak-coprocessor`.
- **Rejected: a state-pointer operand with coprocessor loads.** It needs the unimplemented `x_mem` channel.
- **Rejected: `kxor` taking two lanes (`rs1`, `rs2`) with an implicit counter.** It saves ~8 instructions per block but adds hidden state and makes save/restore non-trivial.

Expected cost per SHA3-256 block: 17 × (`ld` + `kxor`) + 1 `kperm`, or 24 `shatr`. Squeezing costs 4 `krd` per digest.

### D3 — Coprocessor microarchitecture: one in-flight instruction, registered result

`hw/coproc/` will hold three modules:

- `keccak_round` — the combinational round function θ ρ π χ ι, with the round constant as an input. It is shared with the accelerator.
- `keccak_cvxif` — the coprocessor.
- `keccak_mmio` — the accelerator.

`keccak_cvxif` holds 25×64 state flops, a busy flag and a round counter.

- **Issue.** Decoding is combinational. Valid `funct3`/`funct7` combinations get `accept = 1`, and for non-writing instructions so does `rd = x0`. `writeback = 1` is set only for `krd`. Anything else gets `accept = 0`, and CVA6's own illegal path raises the exception.
- **Why non-writing instructions must use `rd = x0`.** The pinned CVA6 has a forwarding bug, found in task 1.7. In the writeback cycle, `scoreboard.sv:328` forwards a writeback port's data to any source register equal to the entry's `sbe.rd`. For a CV-X-IF result with `we = 0`, `rd` is cleared to `x0` only in `mem_n` (line 191), which takes effect a cycle later. So an instruction that reads `rd` immediately after a non-writing offload receives the coprocessor's result data, even though the register file is never written. The task 1.7 observation: a `beq` after the stock `custom-1` op saw `5 + 7` instead of the sentinel `0xc0ffee`, while a later `mv` read `0xc0ffee` correctly. Rejecting `rd ≠ x0` at issue makes the path unreachable without a core change. Rejected alternative: returning a "harmless" result value. The coprocessor cannot know `rd`'s old value, so no value is harmless.
- **`x_issue_ready`** is low while an instruction is in flight, so there is at most one at a time. This guarantees the program order the spec requires without a FIFO. The example coprocessor's 8-deep FIFO was rejected: with single issue it buys no throughput and adds ordering cases.
- **Result.** `x_result_valid` is registered one cycle after accept for `kclr`, `kxor`, `krd` and `shatr`, and after `24/R` cycles for `kperm`. Registering it keeps the 25:1 64-bit lane mux and the round logic off CVA6's issue→writeback path, so the core's own critical path is unchanged.
- **Out-of-range index.** A lane or round index that is out of range is accepted, then completes with `exc = 1` and `exccode = 2`, and the state is not written. The index lives in a register, so it cannot be rejected at decode.
- **`R` (rounds per `kperm` cycle)** is a synthesis parameter in {1, 2, 3, 4, 6}, the divisors of 24 up to 6. The datapath instantiates `R` chained `keccak_round` copies, and `shatr` taps the first copy. The value used in the SoC build comes from the sweep defined in `specs/sha3-evaluation`.

### D4 — Integration: one Cheshire fork patch (port + config field)

- **Enable the port through Cheshire's config.** Fork tag `v0.3.1-newt.2` adds a `cheshire_cfg_t` field `Cva6CvxifEn` (`DefaultCfg`: 0), which `gen_cva6_cfg()` maps to CVA6's `CvxifEn`. `hw/iguana_pkg.sv` sets `ret.Cva6CvxifEn = 1`. This changes no CVA6 RTL, and the switch lives in the project's own config.
- **Rejected: `CVA6ConfigCvxifEn=1` in `IG_CVA6_PKG_PARAMS`.** It rewrites only the package default, which Cheshire's explicit `CVA6Cfg` overrides, so it would be a silent no-op (see Context).
- **Rejected: hard-coding `CvxifEn : 1` in the fork.** It would flip the switch for every user of the tag.
- The same tag adds `cvxif_req_o`/`cvxif_resp_i` ports to `cheshire_soc`, wired to core 0's `cvxif` port; further cores keep the tie-off. Cheshire's own instantiation sites (sim fixture, Xilinx top) leave the request open and tie the response to `'0`, which is the old behaviour. The tag resolves to `7b53138`.
- `iguana_soc` instantiates `keccak_cvxif` and connects it.
- **Rejected: instantiating the coprocessor inside `cheshire_soc` in the fork.** That would put thesis RTL in a dependency fork, and it would break the `hw/coproc/` convention the CI stubs key on.

### D5 — Speculation hazard: characterise and constrain, don't fix in-core

There is no kill signal (see Context). An older instruction can raise an exception at commit after a younger coprocessor instruction has already changed the state. That older instruction is a load or store fault, or the instruction at which an interrupt is taken. The flushed coprocessor instruction is then re-executed after the handler, and `kxor` or `shatr` gets applied twice.

**Branch mispredicts.** CVA6 resolves branches in the cycle they execute, and `flush_i` clears `cvxif_valid_q`. So mispredicts are expected to be safe, but this needs confirmation.

**Decision:**

1. A directed SoC test (`specs/keccak-coprocessor`, "constraint is characterised") triggers a timer interrupt mid-sequence and records whether any instruction was applied twice.
2. Every program in this change runs coprocessor sequences in M-mode, from SPM, with `mstatus.MIE = 0`. In M-mode without paging, an older memory instruction can fault only on a bad address, and the benchmark code does not issue such accesses.
3. The constraint is written up as a documented limitation and as thesis future work.

**Rejected alternatives:**

- **Fork CVA6 to drive `x_commit_kill` from the scoreboard.** It violates the "no core RTL change" property that the contribution rests on.
- **Shadow state committed later.** The coprocessor never learns when an instruction commits.
- **Restricting the ISE to idempotent operations.** That removes `kxor` and `shatr`.

### D6 — MMIO accelerator on the AXI external subordinate port, fed by CPU or iDMA

- **Bus.** `keccak_mmio` sits behind `axi_to_detailed_mem`, from the already-pinned `axi` 0.39.6, which supports error responses. It has 64-bit data and is connected through `CheshireCfg.AxiExtNumSlv = 1` with one region.
- **Address window.** `0x5000_0000`–`0x5000_0FFF` is proposed. It must lie in the external **non-CIE** range `[0x4000_0000, 0x8000_0000)`. With `DefaultCfg`'s `Cva6ExtCieLength = 0x2000_0000`, the range `[0x2000_0000, 0x4000_0000)` is cached, idempotent and executable for CVA6, so the originally proposed `0x2000_0000` would have been cached, which is wrong for MMIO. The chosen window sits just above the hyperbus config window `[0x4000_0000, 0x5000_0000)`. Task 6.3 verifies that it is free against the generated map before committing to it.
- **Layout.**
  - `0x000`: control (clear, start, rate select).
  - `0x008`: status (busy, done).
  - `0x100`–`0x1C7`: absorb window. A write XORs into lane `offset/8`.
  - `0x200`–`0x2C7`: digest/state read window.
  - Every other offset returns `SLVERR`.
- **Write while busy** is held off by de-asserting the memory grant. This is the simpler of the two behaviours the spec allows, and it means the DMA needs no flow control of its own.
- **Driver modes.** In CPU mode software stores the lanes. In DMA mode, Cheshire's iDMA (enabled in `CheshireCfg`) copies one rate block from SPM into the absorb window.

There is no AXI manager in the accelerator. Reusing iDMA gives the "accelerator fetches its own data" property that the crossover depends on, without writing a second DMA.

**Rejected:**

- **A regbus device.** It needs the `svase.sed` `14` patched, it has a 32-bit data path, and iDMA cannot target it efficiently.
- **The accelerator's own AXI manager.** It is more RTL and duplicates iDMA.

### D7 — Software: project `sw/` tree on Cheshire's runtime

- **Build.** `sw/Makefile` reuses Cheshire's `sw.mk` toolchain variables, `libcheshire` and the `.spm` link script, and emits `*.spm.elf` that the Xcelium bundle stages next to Cheshire's tests. The bundle's test discovery is extended to include `sw/` ELFs.
- **`sw/include/keccak_ise.h`**: `static inline` wrappers built on `asm volatile(".insn r 0x2B, <f3>, 0, %0, %1, %2" …)`, with `rd` hard-wired to `x0` for non-writing instructions. No toolchain change is needed.
- **`sw/lib/sha3_*.c`**: one sponge (FIPS 202 `0x06` padding) with three permutation back-ends (ISE `shatr`, ISE `kperm`, MMIO) and two baseline back-ends.
- **Baselines.** Three, each vendored under `sw/vendor/` with its license and a `REVISION` file (user decision, 2026-10-01):
  - the riscv-crypto reference SHA-3 (`riscv/riscv-crypto` `benchmarks/sha3/reference`). This is the Keccak Team's readable Keccak-f under CC0, called through its own `Keccak()` sponge: the paper's first baseline.
  - XKCP `KeccakP-1600` **`ref-64bits`**, the Keccak Team reference: the paper's second baseline, and the comparator for its 46× figure.
  - XKCP `KeccakP-1600` **`opt64`**, with XKCP's `generic64` build options (all rounds unrolled, no lane complementing; that is `generic64lc`): the fair, optimised software baseline.

  Both XKCP variants are driven through XKCP's own SnP state API (`Initialize`/`AddBytes`/`Permute_24rounds`/`ExtractBytes`), as XKCP's sponge does. Each variant has its own vendor directory and a thin wrapper `.c`, because the two ship identically named headers. The `compact` variant originally listed here is dropped, which keeps the evaluation to three baselines.
- **Build flags.** Everything is built with Cheshire's flags, **`-O2`, `rv64gc_zifencei`**, recorded in the report. `-O3` was rejected as a second variable. Long messages are generated in place from a deterministic pattern, because the 64 KiB SPM cannot hold stored vectors.
- **NIST vectors** live in `sw/vectors/` as generated C arrays. They come from the CAVP SHA-3 byte-oriented `ShortMsg`/`LongMsg` files and are converted by a checked-in script.

### D8 — Measurement method

- **Cycles.** `csrr mcycle` and `csrr minstret` wrap each hash call, and an empty-call calibration run is subtracted. Results go out over UART in a fixed `RESULT,<variant>,<impl>,<bytes>,<cycles>,<instret>` line format.
- **Evaluation script.** `scripts/sha3_eval.py` reads Xcelium results archives. It fits `cycles = a + b·blocks`, then writes CSV plus markdown tables: the speedups shaped like the paper's Table I, the sweep, and the crossover.
- **Simulation budget.** At ~5k cycles/s, baseline runs of 0–4 blocks × 4 variants × 2 baselines take about 1.6 M cycles, roughly 6 minutes.
- **Crossover.** It is located in two passes. A first fit predicts the crossover length, then a second run measures one length on each side of the prediction, as the spec requires.
- **Area.**
  - Two `YOSYS_KEEP_HIER_INST` selectors, for `i_keccak_cvxif` and `i_keccak_mmio`, give per-instance lines in the full-SoC synthesis.
  - The whole-SoC delta is reported against `synth-baseline.json`, alongside Phase 14's ±0.04 % ABC noise band. The baseline is **not** reseeded, because it stays the stock reference.
  - The sweep uses a new standalone block-synthesis make target, shared with CI `synth-coproc`. Each run takes minutes rather than hours.
- **Timing.** Block critical paths come from OpenSTA on the block netlist at the `tt` corner. The SoC figure comes from the P&R lane at the latest stage it reaches, in this order of preference: post-GRT, then post-CTS, then post-placement (`dpl`). The report names the stage that was actually used (Phase 11).
- **Power.**
  - The block unit-testbench hashing workload runs in Verilator with `--trace`, producing a VCD of the block.
  - OpenSTA then runs `read_vcd -scope` on the block netlist from synthesis. Registers and ports are annotated, and the remaining nets use OpenSTA-propagated activity.
  - Energy per byte = P × cycles-per-byte × T_clk. It is reported at the 11.0 ns constraint and at the achieved period.
  - Rejected: SoC-level default-activity `report_power`. It is not workload power.

### D9 — CI graduation

- **`sim-unit`.** Verilator in the `newt-eda` container runs `hw/coproc` unit testbenches. Each testbench is self-checking against a C++ Keccak-f reference compiled into the Verilator harness, and the random lane vectors are seeded and fixed.
- **`synth-coproc`.** It runs the standalone block-synthesis target and fails on any `CHECK` problem.
- **Branch protection.** Both jobs are added to `main`'s required checks. That is a repository-settings action, recorded as a manual task.

### D10 — Synthesis frontend held fixed during measurement (user decision, 2026-10-02)

All PPA numbers in this change (groups 5 and 8) are measured on the **current** frontend, `morty → svase → sv2v → yosys read_verilog`, against the current `synth-baseline.json`. The planned `replace-svase-sv2v-with-read-slang` change (infra-plan Phase 8) lands **after** this change's measurements, not before or in between.

That migration changes cell counts and netlist naming (`gen_cva6_cores.__0` becomes `gen_cva6_cores[0]`). Landing it between the first full-SoC synthesis (task 5.3) and later PPA runs would mix a frontend delta into the coprocessor delta.

**Rejected: migrate first, then measure.** That order is cleaner long-term, but it puts a BREAKING image/CI/backend change that is still at proposal stage on the thesis's critical path. Nothing in this change needs slang. The current chain pickles `keccak_cvxif` cleanly (task 3.2).

Whether the hypervisor extension (ON in the baseline, infra-plan Phase 15) is turned off is the other baseline-moving question. It too must be settled before task 5.3.

## Risks / Trade-offs

- **[Pre-1.0 CV-X-IF handshake bugs in this CVA6 release]** → Task 1 is a smoke test on the Xcelium lane with the stock example coprocessor before any Keccak RTL. If the handshake proves unusable, stop and revisit D1. Changing D1 is a scope decision, not a silent fallback.
- **[Further undocumented decode or forwarding quirks in this CVA6 release]** → Two were found by the task 1.7 smoke test: `custom-0` is `FENCE.T`, and non-writing results are forwarded (D2, D3). The block testbench cannot see either, because both live in the core. So every coprocessor instruction class also gets a directed SoC test with a dependent instruction immediately after it (task 3.6).
- **[`CvxifEn = 1` changes the illegal-instruction path globally]** → A directed `mcause`/`mtval` test and a regression run of the existing passing tests (spec: "Genuinely illegal instruction still traps", "Existing tests unaffected"). The extra cycles an illegal instruction now takes are measured and documented.
- **[Speculation hazard (D5)]** → Characterised by test and constrained by convention. The thesis states the limitation explicitly. The numbers are valid only under that constraint.
- **[`RVB = 0` inflates the speedup]** → The report gives the rotate-synthesis instruction share, as the spec requires. The thesis discusses the speedup a Zbb-equipped baseline would see, labelled as analysis rather than measurement.
- **[P&R lane may not reach CTS/GRT]** → Block-level timing and power come from synthesis plus OpenSTA, and are always available. The SoC-level stage is named, and Phase 11 levers are out of scope here.
- **[RTL-VCD names don't match the netlist, so power annotation falls back to propagation]** → Report the fraction of annotated nets. If it falls below a useful level, switch to gate-level simulation of the block netlist. That switch is a task-level fallback; the method stays activity-annotated as the spec requires.
- **[svase/sv2v reject the new RTL or the CV-X-IF struct ports at the SoC boundary]** → Write `hw/coproc/` in the same restricted SV subset Cheshire already gets through the pickle chain: packed structs, no interfaces. Run `pickle-all` early (task 2).
- **[An AXI-port count is hard-coded somewhere in the pickle patches, as `RegOut.num_out` is]** → Grep the pickled output for xbar port-count elaboration after enabling `AxiExtNumSlv`. The `rtl-dependencies` rule that patches must keep matching applies.
- **[Scope vs internship schedule]** → The task order puts the ISE arm first and the MMIO arm second, so the result is publishable without the MMIO arm.
- **[Coprocessor state is lost or stale across `wfi` or debug halts]** → Out of scope. Benchmarks don't halt mid-sequence.

## Migration Plan

All changes are additive to the default SoC build. Rollback:

1. revert `ret.Cva6CvxifEn = 1` in `hw/iguana_pkg.sv`;
2. revert the Cheshire pin to `v0.3.1-newt.1`;
3. drop the `iguana_soc` instances and `AxiExtNumSlv`.

That restores the stock design, which `synth-baseline.json` describes. The synth lane will report the new cell/area delta as drift. That is informational and does not fail the lane (`ci-pipeline`). No baseline reseed is needed.

## Open Questions

- Whether the final `R` used in the SoC build changes after full-SoC timing is seen. The sweep defines the selection criteria; this question only re-applies them.
