# Proposal

## Why

This project has never had a working licensed simulator. The Questa lane (`ig-sim-rtl`) is inherited from upstream and has never run here. The Verilator lane builds, but it is parked on an unexplained debug-module fault: `DMSTATUS` reads never change. Its design addendum names a licensed-simulator cross-check, run against the same RTL with the reference JTAG driver, as the most likely way to root-cause that fault.

Cadence Xcelium (`xrun(64) 24.03-s004`) is now available, but only on a restricted VM. Files can be copied onto the VM, a simulation can be run there, and result files can be copied back. There is no git, Bender, Docker or network access on it. An Xcelium lane therefore has to be built on the development host as one self-contained archive, run on the VM by one script, and hand back one results archive.

## What Changes

- **New `target/xcelium/` lane, alongside `target/sim/` (Questa) and `target/verilator/`.** It gets its own `xcelium.mk`, included from `iguana.mk` in the same way `verilator.mk` is. The Questa and Verilator lanes are not modified.
- **New testbench (option B from exploration).** It wraps `iguana_soc`, compiled with `-D NO_HYPERBUS` so the DUT is the same one the Verilator lane simulates, and pairs it with Cheshire's own `vip_cheshire_soc` and `vip_cheshire_soc_tristate`. This gives JTAG ELF preload, end-of-computation polling and UART output using Cheshire's reference `jtag_test::riscv_dbg` driver, with no reimplementation. The testbench follows `tb_iguana` but drops the pads, the hyperram model and its 600 µs power-up wait.
- **New host-side target `ig-xrun-bundle`.** It produces one `.tar.gz` that runs on the VM without anything else. The archive contains:
  - an `xrun` argument file with paths relative to the bundle root
  - every source and include directory it references (the Bender dependency closure, about 8 MB rather than the 1.1 GB `.bender/` tree)
  - Cheshire's two `wget`-fetched vendor sim models (SPI NOR flash `s25fs512s`, I2C EEPROM `24FC1025`)
  - the IHP13 behavioral macros
  - Cheshire's DPI ELF loader (`elfloader.cpp`)
  - the prebuilt test ELFs
  - `run.sh`
  - a manifest recording the source revision

  Before archiving, the target checks that every path in the argument file exists in the bundle, so a broken path fails on the host and does not cost a VM round trip.
- **New VM-side `run.sh`.** It compiles and elaborates once, then runs each ELF in the bundle, or a chosen subset. It writes a per-test verdict (`PASS`/`FAIL`/`TIMEOUT`/`ERROR`) from a testbench-printed marker, keeps the compile and run logs, and can optionally dump waves. Everything is packed into one results `.tar.gz` to copy back. It requires only `xrun`, `bash` and standard POSIX utilities.
- **Convenience target `ig-sim-xrun`.** It stages the same bundle and runs `run.sh` in place, for any machine that has `xrun` on `PATH`. Its `BINARY`/`BOOTMODE`/`PRELMODE` variables use the same names as the other lanes.
- **Documentation.** A new `target/xcelium/README.md` describes the copy-in/run/copy-out procedure. `AGENTS.md` and `docs/infra-plan.md` gain a pointer to it. The Verilator change's design addendum gets the result of the DMSTATUS cross-check once it is observed.

- **Cheshire moves to a project-owned fork (added during apply).** Xcelium 24.03 rejects two constant functions in `cheshire_soc.sv`: `gen_axi_map` and `gen_reg_map`. The code is legal SystemVerilog, and no tool option relaxes the restriction. The fork `wortexx/cheshire` gets a branch `newt/v0.3.1`, cut from v0.3.1, which builds both address maps as constant-driven signals instead. It is tagged `v0.3.1-newt.1`, and `Bender.yml` pins `cheshire` by `rev: v0.3.1-newt.1`. Later newt patches continue the series as `v0.3.1-newt.<N>`.

**Flow stages touched:**
- **sim:** the new lane.
- **sw:** the existing prebuilt ELFs are consumed but not changed.
- **RTL dependency pin:** the Cheshire fork. The change is value-identical: the same address-map constants, computed without a constant function. So the pickle/synth input changes textually in `cheshire_soc.sv` only, and synthesis is expected to produce the same netlist. That expectation is verified, not assumed; see tasks.
- **CI (added during apply):** the fast lane's per-file `verilator --lint-only` step skips `target/xcelium/src/`. Verible still lints those files. See design D8.
- **Not touched:** backend. Nothing is added to the Questa compile scripts, the Verilator file list, or the pickle patch set.

## Capabilities

### New Capabilities

- `xcelium-sim`: an Xcelium simulation lane for a restricted, offline VM. It covers the self-contained bundle (contents, relative paths, host-side completeness check, provenance manifest), the single-script run on the VM with per-test verdicts and a single results archive, runtime test selection, and coexistence with the Questa, Verilator and synthesis flows.

### Modified Capabilities

- `rtl-dependencies`: "Cheshire is pinned to a released tag with an exact lock". The pin moves from upstream `version: 0.3.1` to the fork tag `v0.3.1-newt.1`. The requirement already permits a commit in a project-owned fork, so only the recorded values and their scenario change.
  - *Merge note:* this capability is introduced by the not-yet-archived `bump-cheshire-v0-3-1` change. That change must archive first, so that this delta has a main spec to modify.

`ci-pipeline` requirements are unchanged: this lane runs manually on a machine CI cannot reach, and adds no job or stub. The one lint-step adjustment (design D8) keeps the existing "lint changed RTL" requirement meaningful for a testbench that Verilator cannot lint per file; it does not change the requirement.

## Impact

- **New files:**
  - `target/xcelium/xcelium.mk`
  - `target/xcelium/src/` (testbench and fixture)
  - `target/xcelium/run.sh`
  - `target/xcelium/README.md`
- **Changed files:**
  - `iguana.mk`: one `include` line
  - `.gitignore`: bundle staging and output directories
  - `AGENTS.md` and `docs/infra-plan.md`: documentation pointers
- **Host prerequisites:** the existing `bender`, the riscv64 toolchain (for `ig-sw-all`), and network access once, to fetch Cheshire's two vendor models through the existing `chs-sim-all` rules. Nothing new is added to the `newt-eda` image.
- **VM prerequisites:** Xcelium 24.03 (`xrun`), `bash`, `tar`/`gzip`, and a C++ compiler reachable by `xrun` for the DPI ELF loader. Xcelium ships one.
- **Licensing:**
  - The vendor sim models are non-free. They travel only inside the bundle, which is never committed (gitignored), the same as the existing `target/sim/models/`.
  - New HDL and scripts carry SHL-0.51 headers.
- **Out of scope:** DRAM-backed tests (`iguana_soc` does not expose the LLC external port under `NO_HYPERBUS`), the pads/hyperram full-chip fixture, gate-level/sv2v/netlist simulation, coverage, and CI integration.
