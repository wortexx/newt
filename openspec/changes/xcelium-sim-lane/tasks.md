# Tasks — Xcelium Simulation Lane

Tool legend:

| Tag | Meaning |
| --- | --- |
| **[edit]** | Plain file editing, verifiable without EDA tools |
| **[host]** | Needs the host or `newt-eda` toolchain: bender, the riscv64 gcc, and network access for the vendor-model fetch |
| **[vm]** | A manual round trip to the restricted Xcelium VM: copy the bundle in, run `run.sh`, copy the results archive back. Every [vm] task is a human step and is the expensive unit here, so batch checks into as few round trips as possible. |

No synth or P&R runs anywhere in this change.

## 1. Bundle generation (host side)

- [x] 1.1 **[edit]** Create `target/xcelium/xcelium.mk` (SHL-0.51 header) and include it from `iguana.mk` right after the `verilator.mk` include. Also add `target/xcelium/build/` and `target/xcelium/out/` to `.gitignore`.
  - Verify: `make -n ig-xrun-stage` parses.
  - Verify: `git diff iguana.mk` shows only the one `include` line.
- [x] 1.2 **[host]** Add the file-list rule. It runs `bender script flist-plus -D FUNCTIONAL -D NO_HYPERBUS` over `rtl simulation test asic ihp13 cva6 cv64a6_imafdcsclic_sv39`, filters out `target/sim/src/{fixture,tb}_iguana.sv`, strips the `$(IG_ROOT)/` prefix, and appends the lane's testbench sources and Cheshire's `elfloader.cpp`. The result is written to `build/bundle/xrun.f`.
  - Verify: the list contains `iguana_soc.sv`, `cheshire_soc.sv`, `vip_cheshire_soc.sv`, `jtag_test.sv`, `s25fs512s.v`, `24FC1025.v` and the IHP13 SRAM behavioral models.
  - Verify: the list contains no `s27ks0641`, `fixture_iguana` or `tb_iguana`.
  - Verify: no line starts with `/`.
  - Done: 654 files and 16 include dirs; all required entries present, none forbidden, no absolute paths. Bender lists `hw/iguana_pkg.sv` and CVA6's `instr_tracer_pkg.sv` under two targets each, so the list is de-duplicated, keeping the first occurrence.
- [x] 1.3 **[host]** Add staging. It copies every file and `+incdir+` directory named in `xrun.f` into `build/bundle/`, preserving repo-relative paths. It copies `$(XRUN_ELFS)` (default: `$(CHS_ROOT)/sw/tests/*.spm.elf`) into `build/bundle/elf/`, and writes `MANIFEST`. The manifest records the commit, the dirty flag, the `Bender.lock` sha256, the bender and riscv-gcc versions, the ELF list and the generation date. The stage target depends on the two vendor-model files, so `chs-sim-all`'s fetch rules run when they are missing.
  - Verify: running `make ig-xrun-stage` twice produces an identical file tree.
  - Verify: the staged size is in the tens of MB, not GB.
  - Done: two stagings are byte-identical (724 files), staged size 11 MB, archive 1.5 MB. Deviations from the task text:
    - The manifest records the commit date, not a generation date, so re-staging is reproducible.
    - It records no riscv-gcc version: Cheshire's linker scripts drop `.comment`, so the ELFs cannot name their compiler. Each ELF's sha256 pins it instead.
    - The dirty flag also covers untracked files that end up in the bundle.
    - Staging is done by `scripts/stage.sh`. The check ships in the bundle as `check-bundle.sh`, so it also runs on the VM.
    - **Found on the first VM transfer:** the VM reported every `.bender/...` include dir missing, although the archive contained them; the hidden `.bender/` tree did not survive the copy onto the VM. Staging now relocates `.bender/git/checkouts/` to `deps/`, and `check-bundle.sh` rejects any hidden path component. Verified: the archive has 0 hidden entries, and a `cp -R dir/*` copy of the extracted bundle still passes the check.
- [x] 1.4 **[host]** Add the completeness check (design D3), run at the end of staging. Every non-option line in `xrun.f` must exist as a file in the bundle, every `+incdir+` must exist as a directory, and no entry may be absolute. `24FC1025.v` must contain a `module M24FC1025` definition, because the upstream `wget -o` rule can leave a log file in its place. Any failure exits non-zero, names the offending entry, and produces no archive.
  - Verify: delete one staged source and confirm the check fails naming that file.
  - Verify: inject one absolute path and confirm it fails.
  - Verify: overwrite `24FC1025.v` with text and confirm it fails.
  - Done: a deleted source, an absolute path, a `../` escape and a fake `24FC1025.v` each fail, naming the entry. `pack.sh` re-runs the check before `tar`, so a failing bundle is never archived.
- [x] 1.5 **[host]** Add `ig-xrun-bundle`. It tars `build/bundle/` into `out/newt-xrun-<shortsha>[-dirty].tar.gz` with a single top-level directory of the same name.
  - Verify: extract the archive into a scratch directory outside the repo, then `grep -c "$(pwd)" xrun.f` returns 0 and re-running the completeness check from there passes.
  - Done: the archive is `out/newt-xrun-<sha>[-dirty].tar.gz` with one top-level directory. Extracted outside the repo, it has 0 host-path references and the check passes. Also verified with GNU tar as a non-root user in `newt-eda` (Linux): clean extraction, no `._*` files. That needed `--no-xattrs --no-mac-metadata` when packing with macOS bsdtar, which had embedded 61 xattr headers.

## 2. Testbench and run script

- [x] 2.1 **[edit]** Write `target/xcelium/src/fixture_newt_xrun.sv` (SHL-0.51). Instantiate `iguana_soc` with the VIP-facing ports wired as in `fixture_iguana` (JTAG, UART, I2C/SPI through `vip_cheshire_soc_tristate`, serial link), hyperbus outputs left open, and `usb_clk_i`/`gpio_i` tied. Instantiate `vip_cheshire_soc` with `DutCfg = CheshireCfg`, `ClkPeriodSys 10ns`, `ClkPeriodJtag 40ns` and `RstCycles 20`, with its LLC-port request driven to `'0`.
  - Verify: code review against `fixture_iguana.sv` and `fixture_cheshire_soc.sv`. The port list must match `iguana_soc`'s declaration in `hw/iguana_soc.sv`.
  - Done: reviewed, and additionally elaborated on the host with slang (`read_slang --top tb_newt_xrun` in `newt-eda`'s yosys v0.69) over the full bundle. There are zero diagnostics in the fixture/TB: every `iguana_soc` port and the VIP `.*` connections resolve. The check was sanity-tested by injecting a wrong port name, which slang caught. The same run found two duplicate module definitions that change the DUT (`sram`: common_cells `deprecated/sram.sv` vs CVA6 `sram_pulp.sv`, which the CVA6 caches instantiate; `configurable_delay`: the hyperbus behavioral model vs `target/ihp13/src/mc_delay.sv`). The extra copies are now excluded, so the lane keeps exactly the definitions the Verilator lane and synthesis use. It also found four standalone dependency testbenches that fail a strict parse; they are excluded because they are never elaborated here. Four slang errors remain, all in shared RTL or the vendor cell library that Xcelium must judge on the VM: `dmi_jtag.sv` use-before-declare, `axi_llc_tag_store.sv` bit→enum, `axi_test.sv` `%h` on a queue, and two `sg13g2_stdcell.v` specify paths. These are watch items for 3.1.
- [x] 2.2 **[edit]** Write `target/xcelium/src/tb_newt_xrun.sv` (SHL-0.51), following `tb_iguana`'s control flow minus the hyperram power-up wait.
  - Plusargs: `+BINARY=`, `+BOOTMODE=`, `+PRELMODE=`, `+IMAGE=` and `+TIMEOUT_NS=`.
  - `BOOTMODE=0` dispatches to the VIP's JTAG, serial-link or UART preload path. `BOOTMODE=2/3` passes through to the VIP's autonomous-boot path.
  - `BOOTMODE=1` and any preload mode other than 0–2 print `[NEWT-XRUN] RESULT UNSUPPORTED <mode>`.
  - On completion it prints exactly one `[NEWT-XRUN] RESULT EXIT=<n>` or `[NEWT-XRUN] RESULT TIMEOUT` line, then `$finish`.
  - Verify: code review against design D2. Every exit path prints exactly one `RESULT` line.
  - Done: every path ends through one guarded `report()` task: EXIT, TIMEOUT from the watchdog, or UNSUPPORTED for BOOTMODE 1/>3, PRELMODE >2, or an unreadable `+BINARY`. The slang check above confirms that every `fix.vip.*` task reference resolves; an injected misspelled task name was caught. A VIP `$fatal` yields no marker, which `run.sh` maps to ERROR.
- [x] 2.3 **[edit]** Write `target/xcelium/run.sh` (SHL-0.51, `bash`, POSIX utilities plus `xrun` only), following design D4.
  - It elaborates once into `build/xcelium.d`, runs the selected ELFs (all of `elf/*.elf` by default, or positional names) with `xrun -R`, and maps `RESULT` markers to `PASS`/`FAIL`/`TIMEOUT`/`ERROR`.
  - It writes `results/summary.txt` and packs `results/` together with `MANIFEST` into `newt-xrun-results-<bundle-id>.tar.gz`.
  - Its exit status is 0 only if every executed test passed.
  - A compile failure still produces the archive, with every selected test marked `ERROR`.
  - It supports `BOOTMODE`, `PRELMODE`, `TIMEOUT_NS` and `WAVES=none|vcd|shm`. `vcd` is scoped to `dmi_jtag`, `dm_top` and the CVA6 debug interface.
  - Verify: `bash -n run.sh` and `shellcheck run.sh` are clean.
  - Verify: on the host, a stub `xrun` placed on `PATH` that prints canned `RESULT` lines produces the expected summary and exit status for pass, fail, timeout, missing marker and compile failure.
  - Done: `bash -n` and shellcheck (the `koalaman/shellcheck:stable` container) are clean on `run.sh`, `check-bundle.sh`, `scripts/stage.sh` and `scripts/pack.sh`. The stub `xrun` produced correct verdicts, exit status, a single compile and one archive for: all-four (PASS/FAIL 3/TIMEOUT/ERROR), pass-only (exit 0), compile failure (all ERROR, archive still written), `PRELMODE=7` (ERROR UNSUPPORTED), an unknown test name, `WAVES=bogus`, and `WAVES=vcd` (scoped `waves.tcl` passed via `-input`). This ran under macOS's bash 3.2. The results archive is named `<bundle-id>-results-<timestamp>.tar.gz`, which is gitignored by `newt-xrun-*`, not `newt-xrun-results-<bundle-id>`, to avoid a doubled prefix.
- [x] 2.4 **[edit]** Add `ig-sim-xrun` to `xcelium.mk` (design D5). It runs `ig-xrun-stage`, then `run.sh` inside the staging directory, passing `BINARY`/`BOOTMODE`/`PRELMODE` through.
  - Verify: with the stub `xrun` from 2.3 on `PATH`, `make ig-sim-xrun BINARY=helloworld.spm.elf` runs only that test.
  - Done: `make ig-sim-xrun BINARY=helloworld.spm.elf` compiled once and ran only that test; `BINARY=` (empty) ran all 8. `BINARY`/`BOOTMODE`/`PRELMODE` are shared with `verilator.mk`, whose `BINARY` defaults to `helloworld.spm.elf`.
- [x] 2.5 **[edit]** Write `target/xcelium/README.md`. Cover:
  - the host prerequisites (`ig-hw-all`, `ig-sw-all`, and the vendor-model fetch)
  - `make ig-xrun-bundle`
  - the copy-in, `./run.sh [tests...]`, copy-out procedure
  - the settings table
  - verdict meanings
  - what is and isn't simulated (no DRAM tests, no pads/hyperram)
  - that the bundle contains non-free vendor models and is not for redistribution

  Add a one-line pointer in `AGENTS.md`'s command reference.
  - Verify: the README's host commands run as written on a clean checkout, up to the archive.
  - Done: `target/xcelium/README.md` written, and `AGENTS.md` gained both a command-reference entry and a repo-layout row. From a clean lane state (build/out and the downloaded vendor models deleted), the documented `make ig-xrun-bundle` re-fetched both models, staged, checked and archived in one invocation; `ig-hw-all`/`ig-sw-all` were already satisfied in this checkout. Extracting a results archive under `target/xcelium/out/` as documented left `git status` unchanged.

## 3. First runs on the VM

- [x] 3.1 **[vm]** Round trip 1: compile and green light. Bundle, copy in, `./run.sh helloworld.spm.elf`, copy back.
  - Verify: `compile.log` elaborates `tb_newt_xrun`. Its log shows "Hello World!". `summary.txt` reports `PASS` with exit 0.
  - If compile fails: fix it with scoped, commented `-nowarn` entries or flags, or with exclusion patterns for test files that are not elaborated (design Risks). Never edit shared RTL. Record each fix here. Budget one extra round trip for this.
  - **Round trip 1 (2026-09-28, over SSH to `sbidnyi@ip-10-0-92-146`, Xcelium 24.03-s004 via `tcsh -c`): compile fails, open.** Found and fixed within the lane:
    - `run.sh` deleted `build/` and xrun will not create `-xmlibdirname`'s parent (`*E,NWRKDRA`); it now creates `build/` first.
    - Bender lists CVA6's `ex_trace_item.svh`/`instr_trace_item.svh` as sources, and compiling them standalone as well as via `` `include `` gave `*E,DUPIDN`. Staging now keeps them in the bundle (reached through `+incdir+`) but out of `xrun.f`.
    - `-disable_sem2009` (from CVA6's recipe) dropped; it was not the cause of the cheshire_soc errors below.
  - **Blocker, shared RTL:** `cheshire_soc.sv`'s `gen_axi_map()`/`gen_reg_map()` constant functions (lines 213–221, 301–309) are rejected by Xcelium 24.03: 18× `CFBADP`, 10× `CFBADT`, 2× `SVNSTP`. Per `xmhelp` this is an Xcelium restriction on constant functions that use module-level localparams and types, and `SVNSTP` is a documented "not currently supported" limitation of type-parameter datatypes. The code is legal SV that Questa and VCS accept, and no flag relaxes it. Per design D6 this is surfaced before any fork.
  - Remaining errors (13) are all in dependency standalone testbenches, which are never elaborated: `tb_axi_xbar`, `tb_axi_iw_converter`, `tb_axi_rt_unit_top`, `axi_riscv_atomics_tb`, `golden_memory`. They can be excluded within the lane.
  - **Green light reached.** With the Cheshire fork, first on a hand-patched experiment bundle and then from the pinned `v0.3.1-newt.1` bundle (5.6), `helloworld.spm` passes: JTAG halt → preload → resume, `[UART] Hello World!`, `RESULT EXIT=0` at 2.19 ms simulated time. Compile+elaborate takes ~47 s on the 2-core, 7 GB VM, and the run ~40 s. Access was over SSH once available; Xcelium's environment comes from `~/.tcshrc`, so commands run as `tcsh -c`.
- [x] 3.2 **[vm]** Round trip 2: whole bundle and failure paths, batched into one trip.
  - `./run.sh` with no arguments runs every bundled `*.spm.elf`.
  - `TIMEOUT_NS` is set far too low for one named test.
  - `PRELMODE=7` is used for one named test.
  - Verify: the summary reports `TIMEOUT` and `ERROR` for those two, and `run.sh` exits non-zero.
  - Verify: the compile step ran once, per the log count.
  - Record the other SPM tests' verdicts as observations, not as gates.
  - Done in one batch from the pinned bundle (`newt-xrun-5ec4197-dirty`):
    - `./run.sh` over all 8 ELFs compiled exactly once. `helloworld`, `dma_2d` and `spm_uncached` gave `PASS`. `axirt_budget`, `axirt_budget_isolate`, `axirt_hello`, `clic_basic` and `clic_multiple` gave `TIMEOUT` at 10 ms. These are observations, not gates: all five hang after resume with no UART output because they target AXI-RT and CLIC, which `CheshireCfg` leaves at Cheshire's defaults (`AxiRt: 0`, `Clic: 0`, despite `iguana_pkg`'s "activated CLIC" comment). This is a SoC configuration fact, not a lane or DUT defect.
    - `TIMEOUT_NS=100000` gave `TIMEOUT`.
    - `PRELMODE=7` gave `ERROR UNSUPPORTED PRELMODE=7`.
    - `run.sh` exited non-zero whenever any test was not `PASS`, and each invocation left its own results archive.
- [x] 3.3 **[vm]** DMSTATUS cross-check for the parked Verilator blocker, which can ride along with 3.1 or 3.2. Run `helloworld.spm.elf` with `WAVES=vcd`, then inspect `dmi_jtag`'s `state_q`/`error_q`/`dmi_req_valid`/`dmi_resp_valid` and the `DMSTATUS` read data on the host in GTKWave.
  - Verify: an entry is appended to `openspec/changes/verilator-sim-flow/design.md`'s addendum. It must say whether `DMSTATUS` changes under Xcelium with the reference driver, and therefore which side of the fork (Verilator harness vs. RTL/config) the Verilator bug is on.
  - Done: the `WAVES=vcd` run of `helloworld.spm` passed, with a 36 MB archive / 1.2 GB VCD scoped to the debug path. `DMSTATUS` goes `0xc0c82` (running) → `0xc0382` (allhalted, 49.0 µs, after `haltreq` at 34.1 µs drives CVA6 `debug_req_i`) → `0xf0c82` (allresumeack, ~486 µs). There were 336 DMI requests and `dmi_jtag.error_q` was never set. Every real `DMSTATUS` has low byte `0x82`, so the Verilator harness's frozen `0x00000011` is not a value this DM can produce: the Verilator bug lies in its C++ DMI read path, not in the RTL or config. Recorded in `openspec/changes/verilator-sim-flow/design.md`'s addendum, with the Xcelium VCD named as the reference trace.

## 5. Cheshire fork pin (added during apply, see design D7)

- [x] 5.1 **[edit]** Create branch `newt/v0.3.1` in `wortexx/cheshire` from upstream v0.3.1 (`5c76406`). Commit the address-map rewrite (`465e9e8`), tag it `v0.3.1-newt.1` (annotated), and push both.
  - Verify: `git ls-remote` shows `refs/heads/newt/v0.3.1` and `refs/tags/v0.3.1-newt.1^{}` at `465e9e8`, with the fork's `main` unchanged.
  - Done: pushed over SSH (HTTPS was refused for lack of the `workflow` token scope). The remote shows the branch and the peeled tag at `465e9e8`, and `main` is still at `21698d4`. No fork CI run was triggered.
- [x] 5.2 **[host]** Repin `cheshire` in `Bender.yml` to `git: https://github.com/wortexx/cheshire.git, rev: v0.3.1-newt.1`, with an explanatory comment, and run `bender update cheshire`.
  - Verify: the `Bender.lock` diff touches only the `cheshire` entry.
  - Done: the lock diff is 3 lines: revision → `465e9e8…`, version → `0.3.1-newt.1`, source → the fork. Every other package is unchanged.
- [x] 5.3 **[eda]** Regenerate hardware and ELFs for the new checkout (`ig-hw-all`, `ig-sw-all`). Confirm the Verilator lane is unaffected apart from the Cheshire path: the regenerated file list differs from the pre-pin one only in the Cheshire checkout directory name.
  - Verify: normalised flist diff is empty.
  - Done: `ig-hw-all` and `ig-sw-all` rebuilt the new checkout (`cheshire-b950f36a6e77f085`) with no tracked-file changes and 8 ELFs. The regenerated Verilator file list is identical to the pre-pin one (998 lines) once the Cheshire checkout directory name is normalised.
- [x] 5.4 **[eda]** Pickle with the fork: `make pickle-all` completes in `newt-eda`, so the rewrite survives morty → svase → sv2v. Also run a full-design `verilator --lint-only` on the lane's file list.
  - Verify: `pickle-all` exits 0, and Verilator lint reports no `%Error`. Value equivalence of the address maps is deliberately left to 5.5: synthesis matching the baseline exactly is a stronger check than diffing two pickles, and diffing would need a second full pickle with the old pin checked out.
  - Done, with the forked Cheshire in `newt-eda`: the full-design `verilator --lint-only` exits 0 with 0 `%Error`, and `make pickle-all` exits 0 in 8m26s. `basilisk.sv2v.v` carries the rewrite as `gen_axi_map` blocks of `assign AxiMap[...]` driven from the `AxiOut` constant, for yosys to fold.
  - Environment note, not a fork issue: on this macOS host the Docker bind mount cannot read or follow symlinks (`Operation not permitted`), and the flow creates two of them (`fpnew_fma.sv`, `cheshire_bootrom.sv`). Both runs therefore used a copy of the repo inside the container's own filesystem. That also made `ig-hw-bootrom-split`'s `cp -n` fail there, because the copy had skipped the unreadable link. Native Linux, such as the CI runner, is unaffected.
- [x] 5.5 **[long]** Synthesis equivalence on the CI synth lane (`full-synth` label on the PR, ~2 h on the Azure runner).
  - Verify: cell count, chip area and DFF count match `synth-baseline.json`, and yosys `CHECK` reports 0 problems.
  - Done: PR #51, synth run 36447894410 (2h15m). yosys `CHECK` reports **0 problems**. The verification criterion was refined because `synth-baseline.json` predates the Cheshire v0.3.1 bump, so the right reference is the v0.3.1 run from #50 (36321657267).
    - Post-mapping, fork vs v0.3.1: cells 735,557 vs 735,837 (−280, −0.04%); area 17,771,117.07 vs 17,776,378.83 µm² (−0.03%); DFFs 89,249 vs 89,209 (+40).
    - Synthesis is deterministic: 4 scheduled runs over 2 commits are identical to the cell, so the delta is real, not noise.
    - The **pre-techmap statistics (`basilisk_generic.json`, `basilisk_pre_tech.json`) are identical in all 69 modules**, including cell counts by type. The rewrite therefore reaches technology mapping as the same logic, and the small post-mapping deltas arise in ABC mapping and the cleanup after it. That is also why they land in modules the fork does not touch: `hyperbus` −231 cells, `cheshire_idma_wrap` −187, `axi_llc_reg_wrap` +40 DFFs, and the flattened top +139 cells.
    - Accepted as equivalent at the logic level. Not bit-identical after mapping, and recorded as such.
- [x] 5.6 **[vm]** Rebuild the bundle from the pinned fork, not a hand-patched copy, and re-run `helloworld.spm` on the VM.
  - Verify: `PASS`, exit 0, the bundle's `MANIFEST` names the pinned `Bender.lock`, and its `cheshire_soc.sv` is the fork's.
  - Done: the bundle rebuilt from the committed pin (`5ec4197`, `Bender.lock` → `465e9e8`) carries the fork's `cheshire_soc.sv` (the `gen_axi_map` generate block), and `helloworld.spm` gives `PASS`, exit 0 (see 3.1/3.2). Its `MANIFEST` names the pinned lock's sha256.

## 4. Integration checks and docs

- [x] 4.1 **[host]** Non-interference (spec coexistence scenarios).
  - Regenerate `target/verilator/build/flist.verilator.f` and confirm it is byte-identical to before the change.
  - Confirm `git diff` of `iguana.mk` is the single `include` line, with `BENDER_SIM_TARGETS`/`SIM_PRE_COMPILE` and every Questa rule untouched.
  - Confirm `git status --short target/ihp13/ target/sim/ target/verilator/` is empty.
  - After generating a bundle and extracting a results archive in the checkout, confirm `git status` shows nothing new.
  - Done, measured against a real baseline: make run once with `HEAD`'s `iguana.mk` (no include) and once with the current one. The regenerated Verilator file list is byte-identical (998 lines), and `make -n -B` output for `ig-sim-rtl` (which covers the Questa compile-script generation command), `pickle-all` and `synth-all` is identical. The Questa script itself cannot be generated in this checkout with or without the change, because the hyperram model was never fetched; that is a pre-existing gap. `git diff iguana.mk` is the one include line. `git status --short target/ihp13/ target/sim/ target/verilator/ hw/ Bender.*` is empty. Extracting a results archive as documented left `git status` unchanged (task 2.5).
- [x] 4.2 **[host]** DUT parity (spec scenario). Diff the design-source subset of `xrun.f` (everything except `target/xcelium/src/`, `target/sim/`, Cheshire `target/sim/`, the vendor models, `elfloader.cpp`, and `test`-target testbench files) against the Verilator file list after normalising paths.
  - Verify: the only differences are in the documented categories, and are listed in this task's notes.
  - Done: 539 of the Verilator lane's 542 entries are shared; the other three are a blank line, `newt_verilator_top.sv` and `verilator.vlt`. The IHP13 macro set is identical: Verilator gets it from a hand list, this lane from Bender's `simulation` block. All 109 Xcelium-only entries fall in the documented categories:
    - VIP/verification IP: `axi_test`/`axi_sim_mem`/`axi_dumper`/`axi_chan_compare`, `apb_test`, `reg_test`, `dmi_test`/`dmi_intf`, `jtag_test`/`jtag_intf`, common_verification, `dram_rtl_sim`, obi test files
    - Cheshire's VIP, its TB/fixture (unused) and vendor models, plus `elfloader.cpp`
    - dependency `test/`/`tb/` testbenches
    - the lane's own TB
    - `pad_functional.sv`, unused and excluded from Verilator only because Verilator cannot parse it
  - Defines: this lane adds only `TARGET_SIMULATION`/`TARGET_TEST`, and no shared source references either. The 90 shared files with `` `ifndef VERILATOR `` guards (mostly assertions) are a simulator-inherent difference, not a DUT one.
- [x] 4.3 **[edit]** Update `docs/infra-plan.md`. Add an Xcelium lane entry in Phase 2, or a new phase if that reads better, recording the restricted-VM workflow, the observed round-trip results from section 3, and the Verilator cross-check outcome.
  - Verify: the document states only observed results, and says so explicitly for any result not yet observed.
  - Done: new `docs/infra-plan.md` Phase 14 ("Xcelium simulation lane"; Phase 13 was already the Cheshire bump), recording only observed results: the bundle, DUT parity, the green light and per-test verdicts, the Cheshire fork with its synth evidence, the findings along the way, and operational notes. Phase 2's parked Verilator green-light item gains the cross-check result.
