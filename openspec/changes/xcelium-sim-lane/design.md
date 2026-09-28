# Design — Xcelium Simulation Lane

## Context

See `proposal.md` for the motivation. This section covers the current state that shapes the approach.

**The restricted VM.** The VM runs `xrun(64) 24.03-s004` and has no git, Bender, container runtime or network. Files move in and out only by manual copy, so every host→VM→host round trip costs real human time. The design should need as few of them as possible, and each one should carry as much as possible.

**Cheshire v0.3.1 (#48) is the base this change builds on.** Its `vip_cheshire_soc` provides:
- clock and reset generation (`clk_rst_gen`)
- JTAG preload and end-of-computation polling through `jtag_test::riscv_dbg` (from `riscv-dbg`, Bender target `test`)
- serial-link and UART preload
- an AXI memory model on the LLC external port: `axi_sim_mem` when `UseDramSys=0`, which is the default; the `dram_rtl_sim` engine otherwise
- the SPI NOR flash and I2C EEPROM vendor models

The two vendor models come in through Cheshire's Bender target `any(simulation, test)` and are fetched by `cheshire.mk`'s `wget` rules (`chs-sim-all`). The VIP's DPI imports (`read_elf` and related functions) are implemented in Cheshire's `target/sim/src/elfloader.cpp`.

**How `iguana_soc` fits.** It wraps `cheshire_soc`. With `-D NO_HYPERBUS` it ties the LLC external response to `'0` internally and does not expose that port. That is the Verilator lane's DUT boundary.

**Bender inputs.** `bender script flist-plus` emits absolute paths, `+incdir+` lines and `+define+` lines. For the Verilator lane's target set it produced 511 files, 11 include directories and about 8 MB of sources. That was measured before the Cheshire bump; the design does not depend on the exact number. The project's own `any(test, simulation)` block in `Bender.yml` adds `fixture_iguana.sv` and `tb_iguana.sv`, which instantiate `iguana_chip` and the hyperram model.

**Other lanes and dependencies.**
- The Verilator lane (`target/verilator/verilator.mk`) is the structural precedent: its own directory, one `include` in `iguana.mk`, generated outputs gitignored, and nothing leaking into shared RTL.
- CVA6 upstream's `xrun` recipe is the starting flag set: `-64bit -sv -access +rwc -timescale 1ns/1ps`, plus a `-nowarn` list.

## Goals / Non-Goals

**Goals:**

- The first iteration should need one round trip, and each further iteration only one more, by catching every host-side-detectable defect before archiving.
- Diagnosis from the results archive alone: logs, a verdict summary and optional waves. No VM session should be needed to understand a failure.
- A result directly comparable with the Verilator lane, because both lanes simulate the same DUT.

**Non-Goals:**

- Running Xcelium from CI, or any automation of the VM transfer.
- Coverage collection, UVM, regression randomization.
- Boot from SPI flash or I2C EEPROM (`BOOTMODE` 2/3) as acceptance criteria. The VIP supports them and the testbench passes the modes through, but only JTAG preload is gated.
- DRAM-linked tests (`*.dram.elf`). The DUT boundary has no LLC port.

## Decisions

### D1: The testbench is a new fixture around `iguana_soc` plus Cheshire's VIP (option B)

`target/xcelium/src/` holds two files:
- `fixture_newt_xrun.sv`: instantiates `iguana_soc`, `vip_cheshire_soc` and `vip_cheshire_soc_tristate`. The VIP parameters are `DutCfg = iguana_pkg::CheshireCfg` and the same clock, JTAG and reset timing as `fixture_iguana` (10 ns / 40 ns / 20 cycles).
- `tb_newt_xrun.sv`: the control flow cribbed from `tb_iguana`.

The VIP's `axi_llc_mst_req` input is driven to `'0` and its response is left unconnected. Its `axi_sim_mem` then sits idle, which is harmless.

- *Alternative: reuse `fixture_iguana`/`tb_iguana` verbatim (option A).* Rejected. It needs the pads, the hyperram vendor model (only distributed as a Windows self-extractor) and SDF, and it spends 600 µs of simulated time on hyperram power-up. None of that bears on the SPM path, and it would stop the result from being comparable with Verilator.
- *Alternative: a minimal testbench that drives `jtag_test::riscv_dbg` directly (option C).* Rejected. It would reimplement about 150 lines of VIP preload and EOC logic that Cheshire already maintains and that `fixture_iguana` already uses.

### D2: The testbench reports its verdict as a marker line, and `run.sh` parses it

The testbench prints exactly one machine-readable line per run:
- `[NEWT-XRUN] RESULT EXIT=<n>` after `jtag_wait_for_eoc`
- `[NEWT-XRUN] RESULT TIMEOUT` from a watchdog `initial` block bounded by `+TIMEOUT_NS=`
- `[NEWT-XRUN] RESULT UNSUPPORTED <what>` for rejected modes

It then calls `$finish`. `run.sh` maps these to `PASS`/`FAIL`/`TIMEOUT`/`ERROR`. A missing marker or a nonzero `xrun` status without a marker also maps to `ERROR`.

- *Alternative: rely on `xrun`'s exit status via `$fatal`.* Rejected as the sole signal. Its mapping of `$fatal` and `$finish` to process status depends on version and options, and it cannot distinguish FAIL from TIMEOUT from a tool error. The marker is unambiguous and survives in the log that comes back.

### D3: The file list comes from `bender script flist-plus`, rewritten to bundle-relative paths

The bundle mirrors the repository layout rooted at the repo top:
- `.bender/git/checkouts/<pkg>/...`
- `hw/...`
- `target/ihp13/...`
- `target/xcelium/src/...`

The argument file is produced from `flist-plus` by stripping the `$(IG_ROOT)/` prefix. The staging step copies exactly the referenced files and include directories, using `rsync -R` or `cp --parents`.

The Bender target set is `BENDER_SIM_TARGETS` minus `hyper_test`, plus `rtl`, with `-D FUNCTIONAL -D NO_HYPERBUS`. That set is `rtl simulation test asic ihp13 cva6 cv64a6_imafdcsclic_sv39`.
- `simulation` brings in the IHP13 behavioral macros through the project's own `all(ihp13, simulation)` block. Unlike the Verilator lane, this lane needs no hand-maintained model list, because it wants Cheshire's vendor models anyway.
- `test` brings in `jtag_test` and the VIP.
- `fixture_iguana.sv` and `tb_iguana.sv` are filtered out by pattern, in the same way the Verilator lane excludes `pad_functional.sv`. They reference the hyperram model and `iguana_chip`, and are not part of this lane's hierarchy.
- **Found during apply:** `simulation`/`test` also bring in second definitions of two modules, which Questa resolves silently by letting the last one compiled win:
  - `sram`: common_cells' `deprecated/sram.sv` vs CVA6's `sram_pulp.sv`. The CVA6 caches instantiate it, so the choice changes the DUT.
  - `configurable_delay`: hyperbus's behavioral model vs `target/ihp13/src/mc_delay.sv`.

  The extra copies are excluded, so the lane keeps exactly the definitions the Verilator lane and synthesis use. Four standalone dependency testbenches that fail a strict parse are excluded too. The list lives in `XRUN_EXCLUDE_PATTERN`.
- `elfloader.cpp` is appended to the argument file, and `xrun` compiles it as DPI.

The host-side completeness check (spec: "Host path leaks are rejected") runs over the finished argument file inside the staging directory:
- every non-option line must name an existing file
- every `+incdir+` must name an existing directory
- no line may start with `/`

- *Alternative: a custom `bender script template` that emits relative xrun syntax directly.* Deferred. It would couple the lane to template-rendering behaviour that differs between the image's bender (0.27.4) and the host's (0.32.0). Prefix-stripping plain `flist-plus` output works on both.
- *Alternative: ship all of `.bender/` (1.1 GB) and the PDK (500 MB).* Rejected. It is about 200 times larger than the closure, which matters for manual transfer.

### D4: `run.sh` compiles once, runs many, and packs one archive

1. `xrun -64bit -elaborate -f xrun.f -top tb_newt_xrun -xmlibdirname build/xcelium.d -l results/compile.log` runs once.
2. For each selected ELF: `xrun -R -xmlibdirname build/xcelium.d +BINARY=... +BOOTMODE=... +PRELMODE=... +TIMEOUT_NS=... -l results/<test>/run.log`.
3. `results/summary.txt` is written, as a table of test, verdict and exit code.
4. `results/` is packed together with a copy of the bundle `MANIFEST` into `<bundle-id>-results-<timestamp>.tar.gz`.

Settings are environment variables or `run.sh` options: `BOOTMODE`, `PRELMODE`, `TIMEOUT_NS`, `WAVES`, and positional test names. Waves are off by default. `WAVES=vcd` dumps a scope limited to the debug path (`dmi_jtag`, `dm_top` and the CVA6 debug interface), sized for the Verilator cross-check and viewable on the host with GTKWave. `WAVES=shm` writes a full-access SHM for SimVision on the VM.

- *Alternative: recompile per test.* Rejected. Each run would repeat minutes of elaboration for no benefit, because the ELF path is a plusarg.

### D5: Make targets live in `target/xcelium/xcelium.mk`

The file is included from `iguana.mk` right after `verilator.mk`.

| Target | Runs where | Does |
| --- | --- | --- |
| `ig-xrun-stage` | host | builds `target/xcelium/build/bundle/` (file list, copies, ELFs, `run.sh`, MANIFEST), then runs the completeness check |
| `ig-xrun-bundle` | host | `ig-xrun-stage`, then tars the tree to `target/xcelium/out/newt-xrun-<shortsha>[-dirty].tar.gz` |
| `ig-sim-xrun` | any machine with `xrun` | `ig-xrun-stage`, then `run.sh` in the staging directory, with `BINARY`/`BOOTMODE`/`PRELMODE` passed through. It exercises exactly the same `run.sh` as the VM. |

The bundle carries the `*.spm.elf` files from `$(CHS_ROOT)/sw/tests/`, overridable with `XRUN_ELFS=`. The target depends on the vendor-model files, so a missing model triggers `chs-sim-all`'s fetch rules. The target does not depend on `ig-sw-all`: building the software is left to the user, and a missing ELF produces a clear error.

### D6: No change to shared RTL or other lanes

The Xcelium-specific code consists of the fixture, the testbench, `run.sh` and the flag set. It all lives under `target/xcelium/`. Any Xcelium-specific RTL workaround must be a `-nowarn` or flag in the argument file or `run.sh`, never an edit to shared sources, per the spec's coexistence requirement. A construct that Xcelium cannot compile even with flags is surfaced to the user before any fork is considered.

### D7: Cheshire goes to a project fork for its address-map functions (added during apply)

The first VM compile showed that Xcelium 24.03 rejects `cheshire_soc.sv`'s `gen_axi_map()` and `gen_reg_map()`: 18× `CFBADP`, 10× `CFBADT`, 2× `SVNSTP`. `xmhelp` documents these as a restriction on constant functions that use module-level localparams and types, plus a "not currently supported" limitation. No option relaxes them. The code is legal SystemVerilog: Questa, VCS, Verilator and slang all accept it.

- **Fix, in `wortexx/cheshire`:** replace both constant functions with generate loops of constant continuous assignments to `AxiMap`/`RegMap`. Both maps only ever feed `addr_map_i` input ports, never a constant context, so the values are identical and synthesis folds them to the same constants. The fix was proven on the VM before anything was committed: with the rewrite, the bundle compiled and elaborated with 0 errors and `helloworld.spm` passed.
- **Versioning:**
  - Branch `newt/v0.3.1` is cut from upstream v0.3.1 (`5c76406`), not from the fork's `main`. `main` tracks upstream and is 49 commits and about 12k lines ahead, which would drag a large unrelated RTL update into every flow.
  - Annotated tags follow `v0.3.1-newt.<N>`. The dotted counter keeps semver precedence numeric, so `newt.10` > `newt.2`.
  - The pin is `rev: <tag>` rather than a `version:` range, because semver ranks the pre-release `0.3.1-newt.N` *below* `0.3.1`, and plain ranges do not match pre-releases.
- *Alternative: patch `cheshire_soc.sv` inside the Xcelium bundle only.* Rejected. It breaks the project's "forks, not patches" rule, and the lane's DUT-parity requirement: Xcelium would simulate different source text than Verilator and synthesis. A CV-X-IF fork of Cheshire was expected for the thesis anyway.
- *Push mechanics:* pushing the branch over HTTPS was refused because the `gh` token lacks the `workflow` scope, which is needed since the v0.3.1 base carries older `.github/workflows/*`. The push went over SSH as `wortexx`.

### D8: The fast lane's per-file Verilator lint skips the Xcelium testbench (added during apply)

PR #51's `lint` job, a required check, failed on `tb_newt_xrun.sv`. The testbench drives Cheshire's VIP through hierarchical task calls (`fix.vip.jtag_init()`, the same pattern `tb_iguana` uses), and under the step's deliberately per-file lint the dotted reference into a module outside the file is a hard Verilator error. `-Wno-MODMISSING` covers missing instances but not dotted references, and the VIP (classes, DPI, vendor models) is not verilatable anyway. `fixture_newt_xrun.sv` linted clean.

The step now skips `target/xcelium/src/*`, with a comment. Verible still lints those files, and they are checked for real by Xcelium and by the host-side slang elaboration.

- *Alternative: restructure the testbench to avoid dotted calls.* Not possible without re-implementing the VIP; merging fixture and TB still leaves `vip.*` pointing into a module outside the per-file scope.

## Risks / Trade-offs

- **Xcelium rejects or warns on constructs across Cheshire, iDMA or axi_llc that Questa tolerates.** → Start from CVA6's flag set plus `-disable_sem2009`. Treat the first round trip as a compile-cleanup iteration, and budget a second in tasks. Scoped `-nowarn` entries each get a comment. Errors are surfaced, not waived blindly.
- **The `test` target pulls in every dependency's testbench files (axi `test/*.sv`, `tb_jtag_dmi.sv` and others).** They compile but are never elaborated. If one fails to compile under Xcelium, it is excluded by pattern like `fixture_iguana`. A slang-based `--top` trim is available in host bender 0.32 but not in the image's 0.27.4, so it is not relied on.
- **The unselected `gen_dramsys` branch references `dram_sim_engine` / `axi_dram_sim`.** These exist if `dram_rtl_sim`'s sources are in the list. If `xrun` requires definitions for unelaborated generate branches and they are missing, include `dram_rtl_sim`'s RTL rather than patching the VIP.
- **`cheshire.mk`'s `24FC1025.v` rule uses `wget -o` (a log file), not `-O`.** It still works: the zip lands in the current directory under its own name and `unzip -p` reads it. But it leaves a stray zip in the working directory and depends on where the command runs. → Verify the fetched file is Verilog, not a log, in the completeness check (look for the `module M24FC1025` definition).
- **Non-free vendor models travel in the bundle.** → The bundle and results never enter git (`target/xcelium/build/` and `out/` are gitignored). The README states that the bundle is not for redistribution.
- **The VM has no C++ compiler reachable by `xrun` for `elfloader.cpp`.** → Xcelium ships its own GCC and `xrun` uses it by default. If that fails, the fallback is a prebuilt shared object. That needs matching the VM's glibc and is deferred until observed.
- **Waves too large to copy back.** → Waves are off by default, and the VCD scope is limited to the debug path. Full-access SHM is opt-in.
- **Cheshire v0.3.1's VIP has not been exercised yet on this project's config**, not even in Questa. A VIP-side failure would look like a DUT failure. → The green-light test uses the VIP's most-used path (JTAG preload of `helloworld`), and the Verilator comparison localizes the difference.

## Migration Plan

This lane is additive: one `include` line and new files. Rollback means reverting that line and deleting `target/xcelium/`. No other lane's behaviour depends on it.

## Open Questions

- **Timescale and access granularity.** Should the plain run use `-access +r` or a narrower access for speed? Tune after the first observed run time. This does not change the structure.
- **Whether to add a host-side Xcelium-free parse check.** For example, `slang` on the argument file, to catch syntax errors before a round trip. Worth adding only if early round trips are lost to errors a parser would have caught.
