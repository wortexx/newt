# Design — Verilator Simulation Flow

## Context

See `proposal.md` — Why. Current state that shapes the approach:

- The Questa flow simulates `fixture_iguana` → `tb_iguana`: the padded `iguana_chip` (tristate pads), an SDF-annotated s27ks0641 hyperram vendor model, and Cheshire's `vip_cheshire_soc` (behavioral UART/I2C/SPI models, JTAG + serial-link preload tasks). Three of those four layers are not verilatable.
- `iguana_soc` = `cheshire_soc` (with the project's `iguana_pkg::CheshireCfg`) + hyperbus controller on the LLC's external AXI port. The green-light test (`helloworld.spm.elf`, BOOTMODE 0 / PRELMODE 0) runs entirely from the LLC-as-SPM inside `cheshire_soc`; hyperbus is unused.
- Upstream cribs: Cheshire's never-merged 2023 `verilator` branch (`cheshire_testharness.sv` + `cheshire.cpp`: fesvr elfloader, C++-driven clocks/JTAG; but Verilator-4-era — morty pickle, sed/patch hackery, `--no-timing`) and CVA6 upstream's core-level Verilator TB. We have Verilator v5.050 in `newt-eda`, which removes most of the 2023 workarounds' reasons to exist.
- Constraint from the specs: nothing the Verilator lane adds may leak into the Questa compile scripts or the pickle/synth input.

## Goals / Non-Goals

**Goals:**

- A `cheshire_soc`-level Verilator model built with the project's own `CheshireCfg`, so what we simulate is configuration-identical to the taped-out SoC minus pads and hyperbus.
- Runtime-configurable runs (ELF path, boot/preload mode, timeout, optional waves) from one compiled model.
- A flow simple enough to become the Phase 3 CI `sim-soc` job without rework.

**Non-Goals:**

- Simulating `iguana_chip` (pads) or the hyperram model — DRAM-backed tests stay on Questa.
- Gate-level / sv2v / synth-netlist simulation under Verilator.
- The coprocessor unit TB (Phase 7) — though the harness should not preclude reusing its build machinery for a second Verilator top later.
- Matching Questa cycle-for-cycle; functional equivalence of the boot flow is the bar.

## Decisions

### D1: DUT boundary = a purpose-built harness instantiating `cheshire_soc`

New `target/verilator/src/` harness module instantiating `cheshire_soc` directly with `iguana_pkg::CheshireCfg` (mirroring `iguana_soc`'s instantiation, LLC external port tied off), exposing unpacked-scalar ports Verilator handles well.

- *Alternative — verilate `fixture_iguana`*: rejected; pads, SDF, and vendor models cannot verilate.
- *Alternative — verilate `iguana_soc`*: rejected; drags in the hyperbus controller + PHY (delay lines, DDR-ish timing) for no benefit to the SPM path. Can be revisited if a verilatable hyperbus behavioral model ever matters.
- *Trade-off*: the harness duplicates ~100 lines of `cheshire_soc` port wiring; acceptable, and it is the layer where `VERILATOR`-specific code is allowed to live per the spec.

### D2: Feed Verilator the Bender file list directly — no morty pickle

Use `bender script verilator` (or `flist`) with a Verilator-oriented target set (project targets + `cva6`/`rtl` targets, **excluding** the Questa-only `test`/`hyper_test` vendor-model targets) piped straight into Verilator v5.

- *Alternative — replay the 2023 branch's morty-pickle + patches*: rejected; that existed because Verilator 4 choked on constructs v5 handles, and it adds a second pickle pipeline to maintain.
- *Fallback*: if v5 still trips on specific constructs, first use a `verilator.vlt` config/waiver file scoped to the Verilator lane; fork the offending IP only as a last resort (project dependency strategy).

### D3: Verilator 5 with `--timing`, C++ top (`--cc --exe --build`)

`--timing` tolerates the `#delay`s in behavioral models (e.g. `tc_sram`) without sed surgery. The C++ `main` owns clock/reset/RTC generation (crib: `cheshire.cpp`), argument parsing, and lifecycle — keeping all test-control logic out of SV.

- *Alternative — `--binary` with an SV-only TB*: rejected; ELF parsing, plusarg-driven preload, and timeout policy are much cleaner in C++, and the vip's SV tasks don't verilate anyway.

### D4: ELF preload via JTAG DMI from C++ (PRELMODE 0 semantics)

Port the vip's JTAG preload sequence (debug-module init → halt → system-bus-access writes → set entry point → resume) to C++ bit-banging the harness JTAG pins, using a small ELF loader (fesvr's `elfloader` if linkable from the image toolchain, else a minimal self-written ELF64 reader — decide at implementation, no external-dependency addition allowed either way). End-of-computation detection: poll the same EOC scratch register the vip polls, via DMI; map its code to the process exit status.

- *Alternative — backdoor `$readmem`/hierarchical poke into the SPM*: faster, but bypasses the real boot path (bootrom, boot-mode sampling) — the thing this lane exists to exercise. Keep as an optional later optimization flag, not the default.
- *Alternative — serial-link preload (PRELMODE 1)*: more wiring to model; not needed for green light. Explicitly rejected-for-now; the plusarg interface reserves the mode so it can be added without breaking callers (unsupported modes must error out per the spec).

### D5: UART capture as a C++ bit-sampler on `uart_tx_o`

Sample the TX line at the configured baud/frequency ratio (plusarg with a default matching the sim clock and the test programs' UART init), emit decoded bytes to stdout unbuffered.

- *Alternative — reuse the vip's UART model*: not verilatable (behavioral vendor-style model).

### D6: Make-flow shape mirrors the Questa lane

`target/verilator/verilator.mk` included by `iguana.mk`, adding roughly: `ig-verilator-model` (bender script → verilate → build, dependency-tracked on `Bender.yml`/`Bender.lock`/RTL via Verilator's own `.d` output plus the script regen rule) and `ig-sim-verilator` (run with `BINARY?=sw/tests/helloworld.spm.elf`, `BOOTMODE?=0`, `PRELMODE?=0`, `TIMEOUT_CYCLES?=...` passed as plusargs/args). Naming and variable conventions follow `ig-sim-rtl` so the CI lane and developers see one idiom.

## Risks / Trade-offs

- [CVA6/Cheshire RTL trips Verilator (UNOPTFLAT loops, width warnings, interface edge cases)] → v5.050 + `--timing` first; scoped `verilator.vlt` waivers second; targeted `-Wno-*` only with a comment; IP fork as last resort. Budget existence of this risk into tasks (it is the actual long pole).
- [JTAG-DMI preload is slow for large binaries] → helloworld.spm.elf is tiny; acceptable. If later KAT programs grow, add the backdoor-load flag from D4.
- [UART baud mismatch between sw init and sampler] → make the ratio a plusarg; assert on framing errors instead of printing garbage.
- [Verilator model config drifts from the chip config] → single source: harness imports `iguana_pkg::CheshireCfg`; no local re-parameterization.
- [`--timing` + big design = slow build] → verilation of a CVA6 SoC takes minutes and RAM, not hours; cache the model in CI later (out of scope here).

## Open Questions

- Exact Bender target-set spelling for the Verilator lane (which of `simulation`/`test` targets are needed for `tc_sram` models vs. which drag in vendor models) — resolved empirically during implementation; does not change the approach. **Resolved:** `BENDER_SYNTH_TARGETS` (no `simulation`/`test`) plus a fixed local file list for the IHP13 behavioral macros; see tasks.md 1.1.
- fesvr-elfloader vs. minimal in-tree ELF reader (D4) — pick whichever links cleanly in `newt-eda`. **Resolved:** minimal in-tree reader, adapted from `elfloader.cpp`; see tasks.md 2.4.
- Whether to also wire `--trace-fst` wave dumping behind a Make flag in this change or defer — zero-risk either way. **Deferred** — not needed to make progress on the open blocker below (no waveform viewer available in this environment either way; would need to be paired with a human reviewing the trace).

### Addendum: DM protocol blocker (not resolved — see tasks.md 3.1)

The JTAG-DTM/DM driver (D4) runs the full sequence against real RTL with the
DMI protocol reporting success throughout, but `DMSTATUS` (and separately,
SBA memory reads) return a value that never changes across repeated reads —
including in an isolated experiment that polls `DMSTATUS` 8 times with no
halt request ever issued. Ruled out: TAP-level bit ordering (an isolated
IDCODE readback is correct, including the mandatory LSB=1), the halt
request as the trigger (the no-halt experiment shows the same pattern), and
missing idle time between a DMI read's issue and retrieve shifts (added,
did not change the outcome).

This sits below what a pure C++-driver, no-waveform investigation can
practically resolve further in this environment.

**Update:** found and read `pulp-platform/croc`'s `riscv_dbg_simple`
(`rtl/riscv-dbg/tb/jtag_test_simple.sv`) - a real, low-level reference JTAG-
DTM driver from the same IP lineage (`riscv-dbg`), doing the same raw TAP
bit-banging this driver does rather than a UVM-style abstraction. It exposed
a real gap: `dm_pkg.sv`'s DMI error/busy latch (`error_q`) is sticky and, per
`dmi_jtag.sv`, blocks all further DMI Idle-state acceptance until an explicit
`dtmcs.dmireset` (IR=`DTMCSR`=`0x10`, a *different* scan chain from
`DMIACCESS`) is issued - `read_dmi_exp_backoff` in that reference resets
before every retry. This driver never did that at all. Implemented: IR
tracking (`SelectIr` now only shifts when the target IR differs, matching
`jtag_driver_simple::set_ir`'s early-return, which is what makes it cheap to
call before every DMI access rather than assume IR stays latched), a
`WriteDtmcs`/`ResetDmi` pair, and calling `ResetDmi()` before every busy-retry
in `DmiRead`/`DmiWrite`. Real, worth keeping regardless of outcome - but it
did **not** change the observed symptom: this driver's traces never showed
`resp=BUSY` in the first place (always `resp=0`, with frozen data), so the
retry-then-reset path was never exercised. The root cause is still open.

Also read the canonical (unpatched) `jtag_test::riscv_dbg` driver that
`vip_cheshire_soc.sv` itself instantiates (`riscv-dbg`'s
`tb/jtag_dmi/jtag_test.sv`, using SystemVerilog's `{<<{}}}` streaming
operator for bit-(un)packing): confirms this driver's MSB-first send order
and same-address NOP-retrieve trick already match the canonical reference
exactly. No new divergence found there.

**Decision (2026-09-01): deferred to a follow-up, not blocking further
infra work.** The most likely way to actually root-cause this is a
licensed-simulator cross-check - either a real Questa run (e.g. from a
Linux VM, sidestepping this environment's Docker/virtiofs bender issue
entirely) or standing up an Xcelium lane (evaluated as feasible: Xcelium
fully supports the class-based `jtag_test.sv` driver, unlike Quartus's
bundled free ModelSim edition which does not support SystemVerilog classes
at all; would need `bender script flist-plus` + a hand-ported do-file,
since Bender has no native `xcelium` script target) - run against the
*same* RTL, with a waveform dump around one DMI transaction. That is not
worth blocking Phase 3 CI setup on securing a license/VM for, so this is
parked rather than actively pursued right now.

The lowest-cost angle that stays available without any licensed simulator,
for whoever picks this back up: get an FST/VCD trace of a short repro (the
no-halt `DMSTATUS`-only poll, described above) straight out of this
Verilator harness and inspect `dmi_jtag.sv`'s `state_q`/`error_q`/
`dmi_req_valid`/`dmi_resp_valid` directly - this is a small, fast repro,
not the full boot sequence.
