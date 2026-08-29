# Thesis Plan: Custom RISC-V ISA Extension Through the Full Open ASIC Flow

Working title: *A CV-X-IF Crypto Coprocessor for CVA6 in Basilisk: From RTL to Silicon-Realistic PPA on an Open 130nm Flow*

Target repo: [`pulp-platform/cheshire-ihp130-o`](https://github.com/pulp-platform/cheshire-ihp130-o) (Basilisk / Iguana), CVA6 host core, IHP SG13G2 130nm open PDK, Yosys + OpenROAD flow.

## 1. Problem statement

CVA6 — the 64-bit RISC-V core Basilisk uses as its host core — does not implement any custom instructions today. The CVA6 documentation states this directly:

> "As of now, CVA6 does not implement custom RISC-V instructions. The team is looking for contributors to implement the `fence.t` instruction... The user or integrator can also use the CV-X-IF coprocessor interface to implement their own extensions, without modifying the core."
> — [CVA6 docs, *Custom Instructions*](https://cva6.readthedocs.io/en/latest/01_cva6_user/Custom_Instructions.html)

So the documented, non-invasive extension mechanism is **CV-X-IF** (Core-V eXtension Interface), an OpenHW Group open specification for coprocessor-style ISA extensions (crypto, DSP, AI accelerators) that lets a coprocessor be reused across CORE-V cores without touching the core's own RTL. Most published work in this space either (a) modifies the CVA6 pipeline directly to add instructions, or (b) demonstrates extensions on FPGA only. This thesis instead scopes a small extension through CV-X-IF and carries it **end-to-end through Basilisk's real open synthesis/P&R flow** to get physically realistic PPA numbers on an actual fabricable PDK (SG13G2) — something most prior art in this space lacks.

## 2. Relevant configuration already in the repo

`iguana.mk` pins the exact CVA6 configuration Basilisk uses:

```
IG_CVA6_CONFIG := cv64a6_imafdcsclic_sv39
```

with `IG_CVA6_PKG_PARAMS` disabling the hypervisor extension, configuring a 16KB write-through D-cache, `L1CACHE_WAYS := 4` (cache associativity, not a physical partition — see note below), and `SCOREBOARD_ENTRIES := 4`. These parameters matter for the thesis because CV-X-IF instruction issue/retire interacts with the core's existing scoreboard and decode/issue logic — the scoreboard depth in particular affects how many in-flight coprocessor instructions can be tracked, which should be characterized rather than assumed to "just work" with a coprocessor attached.

*(Note: `L1CACHE_WAYS` was initially considered as a possible hierarchical-partitioning knob while researching a separate, parallel thesis topic on the backend flow; confirmed by reading `iguana.mk`/`openroad.mk` that it is purely a cache set-associativity parameter, unrelated to this topic — included here only to avoid the same confusion resurfacing.)*

**Open verification item, not yet confirmed:** which exact CVA6 fork/commit Basilisk's `Bender.lock` pins, and whether that specific commit already exposes a working CV-X-IF port on the core. This should be the first concrete step of the thesis (a half-day spike), since the whole plan depends on it.

## 3. Proposed scoped extension

Pick a **small, well-defined** extension rather than a full crypto suite, to keep the thesis tractable within a typical timeframe. Two reasonable candidates, in increasing order of effort:

- **Lightweight RISC-V scalar cryptography subset** (Zk-family-inspired): e.g. 2–3 instructions covering an AES round function or SHA-256 compression step, modeled on the ratified RISC-V Scalar Cryptography extension semantics but scoped down to what's needed for a thesis-sized coprocessor.
- **Simple DSP/SIMD-style MAC extension**: a fixed-point multiply-accumulate or saturating-arithmetic instruction set, lower implementation risk than crypto but a less differentiated contribution given how much CVA6/DSP-extension prior art already exists.

Recommendation: lean crypto, since it has the most directly comparable, recent prior art (below) and a cleaner story ("first SG13G2-realized PPA numbers for a CV-X-IF crypto coprocessor on CVA6").

## 4. Proposed approach

1. **Verify CV-X-IF availability** on the exact CVA6 version Basilisk pins (open question above).
2. **Implement the coprocessor** as a standalone CV-X-IF-compliant block (decode of custom opcodes, issue/commit handshake, result writeback) — explicitly *not* modifying CVA6's own pipeline RTL, to preserve the "non-invasive" property that's the whole point of using CV-X-IF.
3. **Integrate into Basilisk's `iguana_chip`** top level, following the same RTL-source/Bender-dependency conventions the rest of the SoC uses.
4. **Functional validation** in RTL simulation using the repo's existing `make ig-sim-rtl` flow, with directed tests exercising the new instructions plus regression against existing Cheshire/CVA6 software tests to confirm no disturbance to the baseline core.
5. **Carry through the real flow**: `pickle-all` → `synth-all` (Yosys) → `backend-all` (OpenROAD) on SG13G2, exactly as the rest of Basilisk is built.
6. **Report physically-realized PPA**: area overhead, critical-path/Fmax impact, power, and instruction-level cycle/energy gains for the target crypto operation — and compare against the FPGA-only or different-process-node numbers reported in prior art (below), since a same-operation, real-silicon-PDK comparison is the differentiated contribution.

## 5. Related work and prior art (closest methodological matches first)

- **Closest methodological match (CV-X-IF + CVA6 + crypto):** *"Power Side-Channel Vulnerabilities of a RISC-V Cryptography Accelerator Integrated into CVA6 via Core-V eXtension Interface (CV-X-IF),"* 2025 IEEE International Test Conference (ITC). IEEE Xplore: ieeexplore.ieee.org/document/11219849/. Directly validates the CV-X-IF + CVA6 + crypto combination as a real, published approach; this thesis's contribution is distinguished by carrying the design through actual synthesis/P&R on an open PDK rather than focusing on side-channel analysis.
- **Closest competing prior art, but methodologically different:** CryptRISC (arXiv:2602.20285, Feb 2026, not yet formally published) extends CVA6 directly with a Crypto Functional Unit inserted into the Execute stage of CVA6's six-stage pipeline, supporting 64-bit RISC-V Scalar Cryptography Extensions with field-aware masking/operand randomization. This modifies the core's own RTL rather than using CV-X-IF — an important point to explicitly call out in the thesis's related-work section, since it's the most recent closely-related work but takes the opposite integration approach.
- *"AES-RV: Hardware-Efficient RISC-V Accelerator with Low-Latency AES Instruction Extension for IoT Security,"* arXiv:2505.11880.
- *"Microarchitecture Design and Benchmarking of Custom SHA-3 Instruction for RISC-V,"* arXiv:2508.20653.
- *"Power Side-Channel Analysis of the CVA6 RISC-V Core at the RTL Level Using VeriSide,"* arXiv:2512.21362 — useful methodology reference if any side-channel characterization is attempted as a stretch goal.
- IEEE Xplore paper(s) on RISC-V scalar cryptography extensions (Zkne/Zknh) reporting concrete numbers: ~10% die-area overhead, 42.57x/44.81x cycle-count gains for AES-128/256, 27.81x/28.91x energy-efficiency gains — good target baseline to compare against once Phase 6 numbers are in.
- *"Implementation of a 32-Bit RISC-V Processor with Cryptography Accelerators on FPGA and ASIC,"* IEEE Xplore: ieeexplore.ieee.org/document/9852060/ — directly comparable in that it reports both FPGA and ASIC numbers for a crypto-accelerated RISC-V core, useful as a structural template for how to present this thesis's own FPGA-vs-ASIC (if simulated)/ASIC-only PPA comparison.
- *"Improving the Efficiency of Cryptography Algorithms on Resource-Constrained Embedded Systems via RISC-V Instruction Set Extensions,"* IEEE Xplore: ieeexplore.ieee.org/document/10261964/.
- Basilisk's own EDA-tooling papers (arXiv:2406.15107, arXiv:2405.04257) for the baseline flow context (synthesis/P&R runtime and QoR figures for the unmodified SoC) — useful for distinguishing "cost of the SoC" from "cost of the added coprocessor" in the final area/timing breakdown.

## 6. Evaluation metrics

- **Area overhead**: standalone coprocessor area, and as a fraction of total SoC area (compare against the ~10% die-area-overhead figure reported for Zkne/Zknh extensions elsewhere, as a sanity check).
- **Timing impact**: change (if any) to achievable Fmax for the whole SoC, plus the coprocessor's own critical path.
- **Power**: coprocessor power vs. total SoC power, idle vs. active.
- **Workload-level gains**: cycle-count and energy-efficiency improvement for the target crypto operation vs. a pure-software (RV64 base ISA) implementation, ideally reported the same way as the Zkne/Zknh comparison numbers above (cycle-count multiplier, energy-efficiency multiplier).
- **Functional correctness**: pass/fail on directed instruction tests plus no regression on existing Cheshire/CVA6 software test suite.

## 7. Risks and open questions

- **CV-X-IF availability/maturity** on the exact pinned CVA6 fork/commit — must be verified first; if absent, scope may need to shift to a smaller compatibility-shim effort before any new instructions can be added (this would itself still be a viable, if less novel, thesis core).
- **Scoreboard/issue interaction**: with `SCOREBOARD_ENTRIES := 4`, verify the coprocessor handshake doesn't artificially stall the core or require scoreboard depth increases that change the baseline core's own area/timing (would muddy the "non-invasive" comparison).
- **Scope creep**: cap the extension at 2–3 instructions; a full crypto suite is multi-thesis scope.
- **Side-channel characterization** (suggested by ITC 2025 and VeriSide prior art) is an interesting stretch goal but likely out of scope for a first pass given specialized tooling/time requirements — explicitly flag as future work rather than a deliverable.

## 8. Why this is the lower-risk option among the candidate thesis topics

Compared to a hierarchical-backend-flow thesis (open-EDA flow engineering, higher tooling risk) or a TMR/fault-tolerance hardening thesis, this is a more contained "digital design + real ASIC flow" exercise: a well-specified RTL block, a documented integration interface, and a flow the repo already runs end-to-end for the rest of the SoC. The main risk is front-loaded (CV-X-IF availability) and can be resolved early.

## 9. References

- CVA6 documentation, *Custom Instructions*: https://cva6.readthedocs.io/en/latest/01_cva6_user/Custom_Instructions.html
- PULP Platform, *cheshire-ihp130-o* (Basilisk/Iguana) repository — `iguana.mk`, `README.md`.
- *"Power Side-Channel Vulnerabilities of a RISC-V Cryptography Accelerator Integrated into CVA6 via Core-V eXtension Interface (CV-X-IF),"* 2025 IEEE International Test Conference (ITC), ieeexplore.ieee.org/document/11219849/.
- CryptRISC, arXiv:2602.20285.
- *"AES-RV: Hardware-Efficient RISC-V Accelerator with Low-Latency AES Instruction Extension for IoT Security,"* arXiv:2505.11880.
- *"Microarchitecture Design and Benchmarking of Custom SHA-3 Instruction for RISC-V,"* arXiv:2508.20653.
- *"Power Side-Channel Analysis of the CVA6 RISC-V Core at the RTL Level Using VeriSide,"* arXiv:2512.21362.
- *"Implementation of a 32-Bit RISC-V Processor with Cryptography Accelerators on FPGA and ASIC,"* IEEE Xplore: ieeexplore.ieee.org/document/9852060/.
- *"Improving the Efficiency of Cryptography Algorithms on Resource-Constrained Embedded Systems via RISC-V Instruction Set Extensions,"* IEEE Xplore: ieeexplore.ieee.org/document/10261964/.
- *"Basilisk: An End-to-End Open-Source Linux-Capable RISC-V SoC in 130nm CMOS,"* arXiv:2406.15107.
- *"Insights from Basilisk: Are Open-Source EDA Tools Ready for a Multi-Million-Gate, Linux-Booting RV64 SoC Design?,"* arXiv:2405.04257.
- OpenHW Group, Core-V eXtension Interface (CV-X-IF) specification.
