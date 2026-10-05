# Keccak coprocessor (`hw/coproc/`)

A Keccak-f[1600] coprocessor attached to CVA6 through the core's CV-X-IF port,
with no change to CVA6's RTL. It executes a five-instruction SHA-3 instruction-set
extension (ISE). Planning, rationale and requirements are in
[`openspec/changes/archive/2026-10-05-sha3-cvxif-coprocessor/`](../../openspec/changes/archive/2026-10-05-sha3-cvxif-coprocessor/):
the encoding and behaviour contract is spec `keccak-coprocessor`, and the
microarchitecture is design D2–D5.

| File | What |
|---|---|
| `keccak_pkg.sv` | Lane/state types and the 24 FIPS 202 round constants |
| `keccak_round.sv` | One combinational Keccak-f[1600] round (θ ρ π χ ι), round constant as an input |
| `keccak_cvxif.sv` | The CV-X-IF coprocessor: 1600-bit state, in-order issue queue, FSM, `RoundsPerCycle` chained rounds |
| `keccak_mmio.sv` | The memory-mapped accelerator (comparison arm): an AXI subordinate behind `axi_to_detailed_mem`, same round datapath |
| `tb/` | Verilator unit testbenches and the independent C++ reference (`keccak_ref.h`) |
| `coproc.mk` | `make ig-coproc-unit`: build and run every unit testbench (the CI `sim-unit` job) |

Block synthesis is `make synth-coproc-block BLOCK=keccak_cvxif ROUNDS_PER_CYCLE=<R>`
and `make synth-coproc-all` (the CI `synth-coproc` job), defined in
[`target/ihp13/yosys/block-synth.mk`](../../target/ihp13/yosys/block-synth.mk).
Software intrinsics are in [`sw/include/keccak_ise.h`](../../sw/include/keccak_ise.h),
and the SHA-3 library is in [`sw/lib/sha3.c`](../../sw/lib/sha3.c).

## Instructions

All instructions are R-type on the **`custom-1`** major opcode (`0b0101011`, `0x2B`)
with `funct7 = 0000000`, and are selected by `funct3`:

| Mnemonic | `funct3` | Operands | Writes `rd` | Effect |
|---|---|---|---|---|
| `kclr`  | `000` | — | no (`rd` must be `x0`) | state := 0 |
| `kxor`  | `001` | `rs1` = data, `rs2` = lane | no (`rd` must be `x0`) | state[lane] ^= rs1 |
| `krd`   | `010` | `rs2` = lane | yes | rd := state[lane] |
| `shatr` | `011` | `rs1` = round index | no (`rd` must be `x0`) | one Keccak-f[1600] round with RC[round] (arXiv:2508.20653's `shatr`) |
| `kperm` | `100` | — | no (`rd` must be `x0`) | full 24-round Keccak-f[1600] |

In assembly (no toolchain support needed):

```asm
.insn r 0x2B, 1, 0, x0, a0, a1     # kxor   lane a1 ^= a0
.insn r 0x2B, 4, 0, x0, x0, x0     # kperm
.insn r 0x2B, 2, 0, a2, x0, a1     # krd    a2 = lane a1
```

**Illegal-instruction exception** (`mcause` = 2, state unchanged, no register written):

- another `funct3` (`101`, `110`, `111`) or a non-zero `funct7`;
- a non-writing instruction (`kclr`, `kxor`, `shatr`, `kperm`) whose `rd` field is not `x0`;
- a lane index (`rs2` value) ≥ 25, or a round index (`rs1` value) ≥ 24.

The first two are rejected at issue, so CVA6 raises the exception with `mtval` set to the
instruction. The third completes with an exception result, and `mtval` is 0.

### Why `custom-1`, and why `rd = x0`

Two properties of the pinned CVA6 (`pulp-v1.0.0`, `9338c2ca`) shaped the encoding:

- **`custom-0` is `FENCE.T`.** The decoder maps the whole `custom-0` opcode to PULP's
  `FENCE.T` (`decoder.sv:1381`), whatever `funct3`/`funct7` are. A `custom-0`
  word therefore never becomes illegal and is never offloaded. `sw/tests/illegal_trap.spm.c`
  pins this down.
- **Non-writing offloads forward their result.** In the writeback cycle, the scoreboard
  forwards a CV-X-IF result to any source register equal to the entry's `rd`
  (`scoreboard.sv:328`). It clears `rd` for a `we = 0` result only a cycle later
  (line 191). An instruction that reads `rd` right after a non-writing offload therefore sees
  the coprocessor's result data, although the register file is never written. Measured on
  the SoC: the immediate reader saw `0xc` while the register file held `0xc0ffee`.
  Requiring `rd = x0` makes the path unreachable. `sw/tests/sha3_kat_ise.spm.c` checks that
  `rd ≠ x0` traps and the dependent reader sees the old value.

## State and lane indexing

The coprocessor holds one Keccak-f[1600] state: 25 little-endian 64-bit lanes,
outside the integer register file. Lane `i` holds coordinates `x = i mod 5`,
`y = i div 5` (FIPS 202), and state byte `8*i + k` is byte `k` of lane `i`. A SHA-3 block
of `rate` bytes is therefore absorbed with `kxor` into lanes `0 … rate/8 − 1`.
The state after reset is unspecified, so software executes `kclr` first.

`krd`, `kclr` and `kxor` are sufficient to save and restore the whole state in
software: 25 `krd`, then later `kclr` and 25 `kxor`. There is no OS integration.

## Timing

Accepted instructions enter an in-order issue queue (`fifo_v3`, fall-through) and execute
one at a time from its head. The queue is as deep as CVA6's scoreboard
(`ariane_pkg::NR_SB_ENTRIES`, 4 here). Every offloaded instruction holds a scoreboard entry
until its result is written back, so the queue never fills and `x_issue_ready` stays high.
It has to: CVA6's issue stage dispatches on the previous cycle's `x_issue_ready` and sends
`x_issue_valid` as a one-cycle pulse it never repeats. A coprocessor that drops ready while
busy therefore loses the second of two back-to-back instructions, and the core hangs
waiting for its result (found when the optimised sponge first placed `kperm` right after a
`kxor`). An instruction reaching an empty queue with the datapath idle executes in its
issue cycle, so `kclr`, `kxor`, `krd` and `shatr` still deliver a registered result one
cycle after issue. `kperm` takes
`24 / RoundsPerCycle + 1` cycles, i.e. 25 / 13 / 9 / 7 / 5 for `RoundsPerCycle` = 1 / 2 / 3 / 4 / 6
(`iguana_pkg::KeccakRoundsPerCycle` selects the SoC value).

## Operating constraint: no interrupts or late exceptions during a sequence

CVA6's CV-X-IF implementation in this release has **no kill signal**. `cvxif_fu` ties
`x_commit_kill` to 0 and asserts commit together with issue, and `flush_i` clears only an
instruction not yet sent. An instruction the core has already offloaded is never cancelled.
When an interrupt, or a synchronous exception of an *older* instruction, flushes the pipeline
after a coprocessor instruction was offloaded, that instruction has already changed the
Keccak state. It then executes a second time after the handler returns.

The extension's guarantees therefore hold **only** for code that runs coprocessor
sequences with interrupts disabled (`mstatus.MIE = 0`), and with no older instruction able to
raise a synchronous exception after a coprocessor instruction is offloaded. In M-mode
without paging, this means no access to an invalid address. Every test and benchmark in
`sw/` runs under this constraint.

**Measured** (`sw/tests/keccak_irq_hazard.spm.c`, task 3.7, SoC RTL on the Xcelium lane,
2026-10-01). A CLINT machine software interrupt is raised by a store placed after *j*
coprocessor instructions, with *j* swept across each sequence:

| Experiment | Trials | Interrupt taken inside the sequence | State corrupted |
|---|---:|---:|---:|
| A: 64 × `kxor` into lane 0, bit *k* in the *k*-th | 17 | 16 | 0 |
| B: 5 × `kxor` then 8 × `shatr`, compared with an uninterrupted run | 14 | 11 | 0 |

No interrupted sequence applied any instruction twice. The mechanism is visible in CVA6's
`decoder.sv`. A pending interrupt is decoded as an exception *on the instruction in decode*.
Therefore no younger instruction is issued, and that instruction itself is never offloaded.
Asynchronous interrupts thus cannot reach the no-kill window in this core. The window
remains open for a **synchronous exception of an older instruction**, for example a load
fault detected after a younger coprocessor instruction was issued. The test does not
exercise that case. The constraint above is therefore kept as stated. Relaxing its interrupt
half would be a spec change backed by this measurement and the decoder argument.

## MMIO accelerator (comparison arm)

`keccak_mmio` computes the same Keccak-f[1600] as the coprocessor, reached
over the bus instead of the instruction set. It is the comparison arm of
design D6 and spec `keccak-mmio-accelerator`. It is an AXI subordinate on
Cheshire's external AXI port (`CheshireCfg.AxiExtNumSlv = 1`), behind
`axi_to_detailed_mem`, and has no AXI manager of its own. Its round datapath
is the coprocessor's: `iguana_pkg::KeccakRoundsPerCycle` chained
`keccak_round` instances. The two arms therefore differ only in how they are
reached, and each has its own independent state.

**Base address `0x5000_0000`**, 4 KiB (`iguana_pkg::AxiOutKeccakBase`). The
window sits just above the hyperbus configuration window
`[0x4000_0000, 0x5000_0000)`, inside the external non-CIE range
`[0x4000_0000, 0x8000_0000)`. CVA6 therefore accesses it uncached and
non-idempotent, as MMIO needs.

| Offset | Register | Access | Behaviour |
|---|---|---|---|
| `0x000` | `CTRL` | W | bit 0 `CLEAR`: state := 0, `DONE` := 0. bit 1 `START`: run the full 24-round permutation, `DONE` := 0. bits 3:2 `RATE`: absorb lanes 18 / 17 / 13 / 9 for SHA3-224 / 256 / 384 / 512 (reset: SHA3-256). `CLEAR` and `START` together act as `CLEAR`, then `START`. |
| `0x000` | `CTRL` | R | bits 3:2 `RATE`, all other bits 0 |
| `0x008` | `STATUS` | R | bit 0 `BUSY` (permutation running), bit 1 `DONE` (a permutation finished since the last `CLEAR`/`START`) |
| `0x100 + 8·i` | `ABSORB[i]` | W | lane *i* ^= data, for *i* below the rate's lane count. Byte strobes select the bytes, so narrow stores reach their 64-bit word. |
| `0x200 + 8·i` | `STATE[i]` | R | lane *i*, *i* < 25 (the digest is lanes 0…) |

Every other offset or direction, including an absorb lane past the rate, an
absorb read, and a `STATUS` or `STATE` write, completes with **`SLVERR`** and
changes nothing.

**While `BUSY`, writes and `STATE` reads are held**: the memory grant is
withheld until the permutation ends, and then they apply in order. Software
and the iDMA therefore need no flow control of their own, and `STATUS` stays
readable for polling. A permutation takes `24 / RoundsPerCycle` cycles. The
accelerator has no interrupt; completion is polled.

**Driver modes** (`sw/lib/sha3.c`):

- **CPU:** software stores each rate block's lanes into `ABSORB`, writes
  `START`, polls `STATUS` until `DONE`, and reads the digest from `STATE`.
- **DMA:** Cheshire's iDMA copies each rate block from memory into the
  `ABSORB` window. Software waits for the DMA, then starts and polls as in
  CPU mode. The accelerator does not fetch its own data.

