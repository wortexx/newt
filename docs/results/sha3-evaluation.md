# SHA-3 on CVA6: instruction extension vs MMIO accelerator — evaluation

This is the evaluation summary of OpenSpec change `sha3-cvxif-coprocessor`. It
assembles results; it measures nothing new. Every number below comes from one of
the three generated reports, which carry the full tables, fits and provenance:

- [`sha3-ise.md`](sha3-ise.md): cycles, speedups, rotate share, ISE vs MMIO with
  the message in the D-cache (`scripts/sha3_eval.py`, Xcelium run P).
- [`sha3-mmio-uncached.md`](sha3-mmio-uncached.md): ISE vs MMIO with the message
  evicted from the D-cache (`scripts/sha3_eval.py`, Xcelium run P).
- [`sha3-ppa.md`](sha3-ppa.md): the R sweep, block power and energy, SoC
  synthesis and P&R (`scripts/sha3_ppa.py`).

When this summary and a generated report disagree, the generated report wins.

## What was built

- **ISE (`keccak_cvxif`).** Five instructions on `custom-1` (`kclr`, `kxor`,
  `krd`, `shatr`, `kperm`). The 1600-bit state lives in a coprocessor reached
  through CVA6's CV-X-IF, with the core RTL unmodified. `shatr` runs one
  Keccak-f round (the arXiv:2508.20653 instruction); `kperm` runs all 24, at
  R = 6 rounds per cycle (5 cycles). Encodings and semantics:
  [`hw/coproc/README.md`](../../hw/coproc/README.md).
- **MMIO accelerator (`keccak_mmio`).** The same round datapath behind an AXI
  port at `0x5000_0000`, fed either by CPU lane stores (`mmio-cpu`) or by
  Cheshire's iDMA (`mmio-dma`).
- **Software baselines.** `sw-rvcrypto` (RISC-V reference SHA-3,
  `riscv/riscv-crypto` @ `9cb9087`), `sw-xkcp-ref64` (XKCP ref-64bits, the
  paper's "Keccak Team" baseline) and `sw-xkcp-opt64` (XKCP opt64, the fastest
  portable C), XKCP @ `4affab4`. All built with the same GCC 16.1.0 and
  `-march=rv64gc_zifencei -mabi=lp64d -O2` as the ISE code.

SoC: Basilisk (Cheshire, CVA6 `cv64a6_imafdcsclic_sv39`, hypervisor extension
on per ADR-0004), IHP SG13G2, 11.0 ns clock constraint.

## Correctness

- **Known-answer tests**, on the SoC RTL (Xcelium): 40 NIST vectors per run,
  covering SHA3-224/256/384/512, the empty message, non-multiple-of-8 lengths,
  rate − 1 / rate / rate + 1, and a LongMsg subset.
  - `sha3_kat_ise`: both ISE back-ends PASS. A deliberately corrupted expected
    digest fails with the variant, implementation and vector named (task 3.6).
  - `sha3_kat_sw`: all three baselines PASS (task 4.2).
  - `sha3_kat_mmio`: both MMIO modes, with aligned and unaligned messages, PASS.
    So do the coexistence checks: the ISE state is untouched by an MMIO hash,
    and the reverse (task 6.5).
- **Benchmarks check their own output.** Every timed digest in `sha3_bench` and
  `sha3_bench_long` is compared with an untimed XKCP digest, and
  `sha3_eval.py` refuses results containing a mismatch. This check was added
  after a run in which `mmio-dma` hashed nothing and still produced cycle
  counts (task 7.1).
- **Gate-level.** Every power workload re-checks all 25 lanes against a C++
  reference on the synthesized netlist (tasks 5.2, 5.5, 8.1).

## Speedups (arXiv:2508.20653 Table I form)

Method: `mcycle`/`minstret` around each hash call on the SoC RTL, counter
overhead subtracted, warm caches, interrupts off. The model is split: a
one-block message costs its measured value, and longer messages follow
`a + b·blocks`, fitted on ≥ 2 blocks. All 20 fits are within 1.21 % (ISE within
0.29 %). "Short" sums the NIST ShortMsg lengths (0..rate bytes). "Long" sums
the 100 LongMsg lengths. **All long figures are extrapolated** from the fit,
since they exceed the longest measured message.

Average speedup over the 4 variants × {short, long}. This is the same
averaging that gives the paper's 8.02× and 46.31×, checked by recomputing
those from its Table I.

| ISE | vs | short (mean, range) | long, extrapolated (mean, range) | **mean of 8** | paper |
|---|---|---:|---:|---:|---:|
| `shatr` | `sw-rvcrypto` | 198× (178–221) | 235× (208–276) | **217×** | 8.02× |
| `shatr` | `sw-xkcp-ref64` | 339× (304–377) | 394× (347–466) | **366×** | 46.31× |
| `shatr` | `sw-xkcp-opt64` | 70× (63–78) | 80× (73–93) | **75×** | — |
| `kperm` | `sw-rvcrypto` | 320× (257–377) | 446× (349–609) | **383×** | — |
| `kperm` | `sw-xkcp-ref64` | 546× (438–643) | 750× (584–1,029) | **648×** | — |
| `kperm` | `sw-xkcp-opt64` | 113× (91–134) | 153× (122–206) | **133×** | — |

The per-variant tables are in [`sha3-ise.md`](sha3-ise.md), "Table I".

Per block for SHA3-256 (cycles / instructions): `kperm` 135 / 91, `shatr`
232 / 163, opt64 16,842 / 7,282, rvcrypto 49,614 / 34,978, ref64 82,965 /
57,005.

**Why ours are 27× / 8× the paper's `shatr` figures.** In the paper's Table I,
the custom-instruction run costs only 7.6–8.6× fewer cycles than its RISC-V
software, and long messages still need hundreds of millions of cycles. Our
`shatr` back-end keeps the state in the coprocessor for the whole hash. A block
is then 17 `kxor` plus 24 `shatr`, about 232 cycles, against a 16,842-cycle
opt64 permutation. The paper publishes no encoding, no state-transfer
mechanism and no RTL. The gap is therefore consistent with its instruction
moving state through the register file each round, but that reading is an
inference, not something the paper states. The two baselines also differ in
ratio: the paper's Keccak Team code is ~5.8× slower than its RISC-V code,
while here ref64 is 1.7× slower than rvcrypto.

### Method differences from arXiv:2508.20653

- **RTL simulation instead of gem5.** Cycle counts come from the SoC RTL
  (Xcelium), with CVA6's real pipeline, caches and AXI interconnect, not from
  a cycle-approximate model.
- **ASIC flow instead of FPGA.** Area, timing and power come from IHP SG13G2
  (Yosys, OpenROAD, OpenSTA), not a Kintex-7 at 50 MHz.
- **CV-X-IF instead of in-pipeline execution.** The instructions run in a
  coprocessor behind CVA6's CV-X-IF, with no core RTL change. This adds
  offload latency per instruction, and it creates the interrupt constraint
  below.
- **Message sets.** The paper names no lengths. Here "short" and "long" follow
  the NIST ShortMsg/LongMsg length sets, and long is extrapolated from fits.
- **`kperm`**, a whole-permutation instruction, is this work's addition. The
  paper has only `shatr`.

### The `RVB = 0` effect

The core has no bit-manipulation rotates. Cheshire's `gen_cva6_cfg()`
hard-codes `RVB : 0`, and it does so at struct level, so `IG_CVA6_PKG_PARAMS`
cannot reach it. Each 64-bit rotate therefore costs 3 instructions, or 4 for a
variable amount. The table counts the rotate idioms in the disassembled
baselines and weights them by executions per permutation
([`sha3-ise.md`](sha3-ise.md), "Rotate share").

| baseline | rotate share of dynamic instructions | saving with Zbb `rori`/`rol` |
|---|---:|---:|
| `sw-rvcrypto` | 7.9 % | 5.8 % |
| `sw-xkcp-ref64` | 4.8 % | 3.6 % |
| `sw-xkcp-opt64` | 28.7 % | 19.1 % |

*Analysis, not measurement:* a Zbb-equipped baseline would run at most that
many fewer instructions. If cycles fell in the same proportion, which is an
upper bound because rotates are single-cycle ALU operations and these baselines
are load/store-bound at ~2.4 CPI for opt64, then `kperm` over opt64 would fall
from 133× to at least ~108×, and the rvcrypto and ref64 figures by under 6 %.
The missing rotates inflate the speedup only modestly. Most of it comes from
the state never leaving the coprocessor.

## Design space: rounds per cycle

`keccak_cvxif` block synthesis at every supported R. Stage: block synthesis
(Yosys + OpenSTA, pre-placement), `typ_1p20V_25C`, 11.0 ns.

| R | area (µm²) | vs R=1 | flip-flops | critical path (ns) | slack | `kperm` cycles |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 270,600 | 1.00× | 2,008 | 2.76 | 8.10 | 25 |
| 2 | 387,280 | 1.43× | 2,007 | 3.52 | 7.35 | 13 |
| 3 | 523,133 | 1.93× | 2,007 | 4.24 | 6.63 | 9 |
| 4 | 659,629 | 2.44× | 2,006 | 5.30 | 5.55 | 7 |
| **6** | 941,886 | 3.48× | 2,006 | 7.67 | 3.19 | 5 |

**R = 6 is used in the SoC.** Rule: the largest R that leaves ≥ 20 % slack
(≥ 2.2 ns) at 11.0 ns. Every R qualifies. Measured effect: SHA3-256 `kperm`
costs 135 cycles/block at R = 6, against 155 at R = 1 (−13 %), for 3.5× the
block area. Area × cycles favours R = 1. That was offered as an alternative
and not chosen. The P&R critical path is outside the SHA-3 blocks (below), so
the R = 6 round logic does not limit the SoC clock.

## Area

| | stage | cells | area (µm²) | flip-flops |
|---|---|---:|---:|---:|
| `keccak_cvxif` (R = 6) | block synthesis | 72,526 | 941,886 | 2,006 |
| `keccak_mmio` (R = 6) | block synthesis | 79,446 | 1,004,152 | 2,032 |
| `i_keccak_cvxif` | SoC synthesis, both arms (run 37218328058) | 74,805 | 961,583 | 2,006 |
| `i_keccak_mmio` | SoC synthesis, both arms (run 37218328058) | 63,759 | 857,083 | 2,025 |

Each block is its own kept-hierarchy instance in the SoC report. Each
`YOSYS_KEEP_HIER_INST` selector matches exactly one instance (tasks 3.3, 6.4).

Whole SoC, `typ_1p20V_25C`, against the pre-coprocessor reference run
36447894410:

| SoC | cells | area | flip-flops |
|---|---:|---:|---:|
| + coprocessor (run 37005575294) | +8.90 % | +4.73 % (17.77 → 18.61 mm²) | +2.35 % |
| + both arms (run 37218328058) | +18.74 % | +10.46 % (17.77 → 19.63 mm²) | +5.47 % |

**Noise band.** Untouched modules move by ±0.04 % between synth runs from ABC
alone (infra-plan Phase 14), so the SoC deltas are far outside it. Two effects
are not explained by the blocks' own instances:

- `cva6` shrinks by 34–55 k µm² once CV-X-IF is enabled.
- The same `keccak_cvxif` RTL synthesizes to between 867,261 and 961,583 µm²
  across runs (up to 11 %).

Neither has been investigated. Per-instance SoC areas carry that uncertainty.
The block-synthesis figures come from one consistent flow.

## Timing

| stage | corner | figure |
|---|---|---|
| block synthesis | `typ_1p20V_25C` | `keccak_cvxif` 7.67 ns, `keccak_mmio` 7.46 ns critical path (11.0 ns constraint) |
| SoC P&R, post-global-route (`grt`), before post-route repair | `tt` | WNS −8.23 ns with both arms, against −8.36 ns for the reference (run 37162759719 vs 37108127061) |

The P&R lane stops at `grt` by design, since detailed routing is best-effort.
So `grt` is the latest stage available, and the figures are quoted from it.
These figures are from before post-route timing repair, which the lane skips
by default. A bounded repair was attempted on the reference (run
37512872714). It timed out at its 16 h limit: the incremental re-route after
the repair fell into a congestion cascade and never finished
(`docs/infra-plan.md` Phase 11). So no figure after repair exists for either
side, and the comparison stays at `grt` on both.
WNS barely moves with both arms added, so the SoC critical path is outside the
SHA-3 blocks. The open flow does not close timing on this SoC either way. The
achieved period, 11.0 + 8.23 = **19.23 ns**, is used for energy below. It is a
figure from before repair, not the SoC's maximum frequency: after `cts` the
same run is at −2.70 ns.

**The placements were not legal.** OpenROAD's default legalizer never
converged on this SoC, and `cts` only warned about the result. After `cts`,
12,596 of 844,847 cells (1.5 %) overlapped in the reference and 9,718 of
976,397 (1.0 %) with both arms, so every P&R figure above, on both sides,
comes from a placement with overlapping cells. The comparison treats both
sides alike, but detailed routing cannot run on such a placement: run
37996272102 aborted with `DRT-0218` before routing anything
(`docs/infra-plan.md` Phase 11). Change `use-diamond-legalizer` switches the
flow to a legalizer that places every cell or fails, and makes legality a
gated check. Requoting these figures from legal placements is a separate
decision.

## Power and energy

Stage: block-synthesis netlist, gate-level simulation (Verilator) with the
switching activity annotated into OpenSTA from SAIF. Every run annotates
100 % of pins. Default activity is never used. Corner: `typ_1p20V_25C`, with
an ideal clock and no clock tree. Each workload is SHA3-256 absorb, paced at
the cycles per block measured on the SoC for that implementation and cache
regime. Only the block is counted: **the CPU, caches, iDMA and interconnect
are excluded from every figure.** Energy per byte is at the achieved 19.23 ns
(from `grt`, before post-route repair). Only leakage scales with the period,
so the figures at 11.0 ns differ by < 0.2 %.

| implementation | regime | cycles/block | block power (mW) | energy/byte (pJ/B) |
|---|---|---:|---:|---:|
| `kperm` (coprocessor) | cached | 135 | 12.91 | **141.1** |
| `shatr` (coprocessor) | cached | 232 | 14.18 | 266.2 |
| `mmio-cpu` (accelerator) | cached | 265 | 10.84 | 232.6 |
| `mmio-dma` (accelerator) | cached | 255 | 11.00 | 227.1 |
| `kperm` | uncached | 281 | 10.19 | 231.8 |
| `shatr` | uncached | 377 | 11.67 | 356.1 |
| `mmio-cpu` | uncached | 304 | 10.45 | 257.2 |
| `mmio-dma` | uncached | 253 | 11.02 | **225.8** |

Idle: coprocessor 9.73 mW, accelerator 9.88 mW.

**What dominates.** Neither block's flip-flops are clock-gated, so 69–95 % of
every active power figure is the idle floor, and that floor is almost
entirely clock-pin internal power. As a result, energy per byte tracks cycles
per block much more than the work done.

**The software baselines.** Their energy is CPU energy, which this flow does
not measure, because that would need a gate-level CVA6 simulation. Two bounds
follow from what is measured:

- The baselines take 125× (opt64) to 615× (ref64) the cycles per block of
  `kperm`. The CPU is clocked during the `kperm` run too. So the ISE
  hash costs less total energy than any baseline as long as the coprocessor
  draws less than ~124× the CPU's power, which a 13 mW block easily satisfies.
- The coprocessor is a cost even when unused. Clocked idle during a baseline
  hash, it adds 13,253 (opt64) to 65,284 (ref64) pJ/B, which is 94–463× the
  whole ISE hash energy.

**Clock gating is the main design lever.** It would remove most of the idle
floor in both blocks, which is most of every active figure, and it would make
the always-on cost of carrying the ISE close to zero. It is future work.

**SoC power is not reported.** There is no workload activity for the whole
SoC, and OpenSTA's default activity, which the evaluation spec excludes anyway,
does not converge on this SoC: it stops at its 50-pass cap and gives 0.997 /
9.18 / 0.610 W for the reference / coprocessor-only / both-arms netlists
(infra-plan Phase 17). Under one uniform activity on every net, comparative
only, adding both arms costs +14.6 %.

## ISE vs MMIO crossover (SHA3-256)

This comes from per-implementation linear fits. Every crossover is bracketed
by measured points; every "none" is measured to the longest message the lane
allows and extrapolated to 10,000 blocks. The result **depends on whether the
message is in CVA6's 16 KiB D-cache.** The ISE reads lanes with CPU loads,
while the iDMA reads the SPM in either case.

| cycles/block | cached (`sha3_bench`) | uncached (`sha3_bench_long`) |
|---|---:|---:|
| `kperm` | 135 | 281 |
| `shatr` | 232 | 377 |
| `mmio-cpu` | 265 | 304 |
| `mmio-dma` | 255 (+1,665 one-off) | 253 (+1,537 one-off) |

| pair | cached | uncached |
|---|---|---|
| `kperm` vs `mmio-cpu` | ISE faster at every length (measured to 5 permutations) | ISE faster at every length (measured to 225) |
| `kperm` vs `mmio-dma` | ISE faster at every length (measured to 5) | **`mmio-dma` faster from 64 blocks (8,568 B)**; bracketed by 33 perm. (ISE faster) and 97 perm. (DMA faster) |
| `shatr` vs `mmio-cpu` | ISE faster at every length (measured to 5) | `mmio-cpu` faster at every length (measured to 225) |
| `shatr` vs `mmio-dma` | ISE faster at every length (measured to 5) | **`mmio-dma` faster from 15 blocks (1,904 B)**; bracketed by 9 and 33 perm. |

**Reading.** With the message in the D-cache, the ISE wins everywhere. The
accelerator's own permutation is 4 cycles, but each block also needs software
orchestration: 17 lane stores, or programming the iDMA with seven register
stores and a launch, plus polling STATUS. That costs more than the ISE's
`kxor` stream. With the message out of the cache, the ISE pays for the D-cache
misses, while the iDMA streams from the SPM at about the same cost as before.
The DMA arm then overtakes `kperm` beyond ~8.5 KB.

In accelerator-only energy, `mmio-dma` uncached (225.8 pJ/B) and `kperm`
uncached (231.8 pJ/B) are level. Cached, `kperm` uses 38–39 % less energy
than either MMIO mode. The CPU's share of energy is excluded and differs between
the arms: the CPU drives every `kxor`, but only polls during an iDMA copy.

Area cost of each arm, block synthesis: 0.94 mm² (ISE) against 1.00 mm²
(MMIO), so about the same.

## Operating constraint: interrupts and exceptions

CVA6's CV-X-IF (`pulp-v1.0.0`) has no kill signal for an instruction already
offloaded. If an older instruction raises an exception at commit after a
younger `kxor` or `shatr` has changed the coprocessor state, the younger
instruction is re-executed after the handler and applied twice. The
extension's guarantees therefore hold only with machine interrupts disabled
and no older instruction able to fault synchronously. Every correctness and
benchmark program here runs in M-mode, from SPM, with `mstatus.MIE = 0`.

The directed test `keccak_irq_hazard` (task 3.7) characterises what happens
when the constraint is violated. A CLINT software interrupt was raised inside
`kxor` and `shatr` sequences, at swept positions:

- 64 × `kxor`: 16 of 17 trials interrupted mid-sequence.
- 5 × `kxor` + 8 × `shatr`: 11 of 14 trials interrupted mid-sequence.
- **Result: 0 corrupted states** in both sequences.

CVA6 takes an interrupt as an exception on the instruction in decode, so
nothing younger has been offloaded. **Interrupts are therefore safe in
practice. The hazard that remains is a synchronous exception of an older
instruction**, such as a load or store fault, which the test does not
exercise. Closing it would need a core change (`x_commit_kill` from the
scoreboard), which this work rules out by design. It is listed as future work
(documented in [`hw/coproc/README.md`](../../hw/coproc/README.md)).

## Limitations

- **Provenance.** The cycle figures come from Xcelium run P, a bundle built
  from a clean checkout (`newt-xrun-b1fa596`, task 9.1). The earlier
  dirty-tree runs (`0dee23f-dirty`, `6be5346-dirty`) gave identical figures.
- **Single runs.** Each P&R and SoC synthesis figure is one run. Placement and
  ABC mapping vary from run to run (see the area spread above).
- **Energy coverage.** Energy is block-only, at the typical corner, with no
  clock tree. The CPU and SoC power are not measured (no SoC workload
  activity; default activity does not converge, infra-plan Phase 17).
- **SLVERR.** The accelerator answers undefined accesses with `SLVERR`, but
  CVA6 drops AXI error responses and Cheshire is built with `BusErr = 0`. The
  error is verified only at the block's AXI boundary (task 6.2). On the SoC,
  only the absence of side effects is checked.

## Spec coverage (`specs/sha3-evaluation`)

| requirement | where |
|---|---|
| Known-answer correctness gate | Correctness; tasks 3.6, 4.2, 6.5 |
| Pinned, reproducible software baselines | What was built; the `RVB = 0` effect; the provenance blocks in `sha3-ise.md` and `sha3-mmio-uncached.md` |
| Cycle and instruction counts from RTL simulation | Speedups (method, split model, fit quality); the full fits with residuals and one-block excess are in `sha3-ise.md` |
| Speedups comparable to the reference paper | Speedups; method differences |
| Isolated area of each new block | Area (per-instance lines, selectors, SoC delta with the noise band) |
| Rounds-per-cycle design-space sweep | Design space: rounds per cycle |
| Timing and power with a stated measurement stage | Timing; power and energy (stage, corner, workload, annotated activity; the unavailable SoC power is named with its reason) |
| Measured ISE-versus-MMIO crossover | ISE vs MMIO crossover (bracketed points; "none" stated with the range) |
