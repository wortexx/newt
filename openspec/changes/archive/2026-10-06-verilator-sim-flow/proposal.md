# Verilator Simulation Flow

**Flow stages touched:** sim (new Verilator lane), build system (`iguana.mk` + a new `target/verilator/` or `target/sim/verilator/`), sw (reuse existing prebuilt tests only). No RTL, synth, or backend changes; CI integration is Phase 3, out of scope here.

## Why

Simulation today is Questa-only (`ig-sim-rtl` → `questa-2022.3 vsim`), a paid license the project cannot use in CI. Every meaningful CI lane in the infra plan (lint, unit sim, SoC sim, coprocessor KAT runs) depends on a free simulator — the infra plan calls this the critical-path blocker for RTL CI (Phase 2). The `newt-eda` image already ships Verilator v5.050; nothing can use it yet.

## What Changes

- Add a Verilator build + run flow for the SoC RTL: bender-driven file list, a Verilator-compatible testharness, and Make targets in `iguana.mk` mirroring the existing `ig-sim-rtl` shape (reusing `BENDER_SIM_TARGETS` conventions).
- Port the simulation run configuration (`SIM_PRE_COMPILE`'s `BOOTMODE` / `PRELMODE` / `BINARY` Tcl variables) to Verilator plusargs so the same test binaries drive both simulators.
- The green-light acceptance test: `sw/tests/helloworld.spm.elf` boots, prints over UART, and the simulation exits with code 0 under Verilator.
- Questa targets stay untouched as the local waveform-debug flow.

**Scope notes (recorded assumptions):**

- The Verilator DUT is the digital SoC (`iguana_soc` / `cheshire_soc` level), **not** `iguana_chip`: the chip top's pad ring (tristate `inout`s) and the SDF-annotated s27ks0641 hyperram vendor model in `fixture_iguana.sv` are not verilatable. The SPM-boot green-light test does not need hyperbus/DRAM. Full-SoC-with-hyperram simulation stays Questa-only, exactly the fallback the infra plan anticipates.
- The coprocessor **unit testbench** (listed under Phase 2 in the infra plan) is **not** in this change: it depends on the ISA mechanism decision (CV-X-IF vs `Zknh`, still open in `docs/custom-isa-extension.md`) and on coprocessor RTL that does not exist. It moves to the Phase 7 coprocessor change; this change delivers the simulator infrastructure it will run on.
- Upstream crib sources exist but none is a drop-in: Cheshire has a never-merged 2023 `verilator` WIP branch (morty-pickle + patch hackery, pre-Verilator-5 `--no-timing`) and CVA6 upstream has core-level Verilator support. We target Verilator 5 semantics (`--timing`/`--binary` where useful) rather than replaying the 2023 workarounds.

## Capabilities

### New Capabilities

- `verilator-sim`: the open-source simulation lane — how a Verilator model of the SoC is built from the Bender dependency graph, how a test binary and boot/preload mode are passed at runtime, and what constitutes a passing simulation (UART output, exit code).

### Modified Capabilities

_None._ `eda-tooling-image` already requires Verilator v5.x in the image; no requirement there changes.

## Impact

- **Build system:** `iguana.mk` gains Verilator targets; new files under `target/verilator/` (harness SV + C++ main, Make fragment). Existing Questa targets and `target/sim/` untouched.
- **Dependencies:** none added — Verilator and the riscv64 toolchain are already in `newt-eda`. If RTL constructs in cheshire/cva6/hyperbus trip Verilator, prefer Verilator waivers/config files or `` `ifdef VERILATOR `` guards in the harness layer; forking an IP for lint fixes is a last resort per the project's dependency strategy.
- **Software:** reuses existing `sw/tests/helloworld.spm.elf`; no new test programs.
- **Licensing:** new SV/Tcl/Make files carry SHL-0.51 headers; new C++ harness code carries Apache-2.0 (matching Cheshire's split).
- **Risk:** Verilating the Cheshire fixture/VIP layer is the known hard part (behavioral timing, JTAG/serial-link preload tasks). Mitigation: a purpose-built minimal harness (clock/reset generation + UART decode + ELF preload in C++) instead of reusing `vip_cheshire_soc`.
