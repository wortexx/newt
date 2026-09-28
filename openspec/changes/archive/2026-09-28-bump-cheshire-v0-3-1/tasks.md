# Tasks

Legend: **[edit]** plain editing · **[eda]** needs the `newt-eda` tools (minutes) · **[long]** synth-scale run (hours, non-blocking)

## 1. Capture the "before" reference

- [x] 1.1 **[eda]** On `main` before any edit, run `make ig-hw-all pickle-all` and keep the morty/svase/sv2v pickle outputs and `hw/cheshire_bootrom_split.sv` in the scratch area as the pre-bump reference. Verify: all three pickle files exist, and `grep -c 'gen_dma' ` on the svase output is non-zero.
      Done in `newt-eda:dev`: morty 9.2 MB / svase 10.3 MB / sv2v 13.2 MB, bootrom split 242137 B, `gen_dma` count 2.
      - **Local-environment note.** It had to run on a container-local copy of the repo, in a Docker volume, not the bind mount. On this Docker Desktop virtiofs mount, symlinks the flow itself creates (`ln -sfr` in `ig-hw-fma-opt` and `ig-hw-bootrom-split`) come back as `EPERM` on `statx` inside the container. That is in addition to the already-documented bender hardlink-clone failure (hit again here in `serial_link`'s nested `update-regs` bender call). CI runs on native Linux storage and is unaffected.
      - **Pre-existing finding (on `main`, before any edit).** `patches/morty/wt_axi_adapter.patch` fails 3/3 hunks and `-patch` swallows it. It targets an older CVA6 layout (`AxiDataWidth`, where the pinned CVA6 has `CVA6Cfg.AxiDataWidth`). `wt_axi_adapter2.patch` is the one that applies. CVA6 is not moved by this change; see 3.4.

## 2. Bump the pins

- [x] 2.1 **[edit]** In `Bender.yml`, change `cheshire` to `version: 0.3.1`, `axi` to `version: 0.39.6`, and `register_interface` to `version: 0.4.5` (design D1). Verify: `git diff Bender.yml` shows exactly those three lines.
- [x] 2.2 **[eda]** Produce the new `Bender.lock` per design D2 (revised: Cheshire v0.3.1's own tested lock for its subtree). Verify:
  - `Bender.lock` has `cheshire` at revision `5c76406da7dd0399bb4179f739d1d768cfaf2d8f` / version `0.3.1`.
  - `cva6` revision is unchanged (`9338c2c…`).
  - `hyperbus` is unchanged.
  - Every other package's revision equals Cheshire v0.3.1's `Bender.lock`, except `apb_uart`, which is held at 0.2.1 (design D6; `obi_peripherals` drops out).
  - `bender sources` exits 0.

  Done. What happened:
  - `bender update cheshire` does not exist in the image's bender 0.27.4. On host bender 0.32.0, `update cheshire --recursive` floated 12 packages past Cheshire's tested versions. It also needed interactive resolution of two conflicts that were already in the old lock:
    - `register_interface`: hyperbus wants `^0.3.2`.
    - `axi`: cva6 wants `^0.31`, serial_link and irq_router want `^0.38`.

    Both were resolved to the root requirement.
  - Per the user's decision, the lock was then merged: Cheshire v0.3.1's upstream `Bender.lock` entries for every package it locks, plus our `cheshire` and `hyperbus` entries.
  - Result: 17 packages keep their old revision or take Cheshire's tested one. New packages from the tested set: `axi_stream`, `dram_rtl_sim`, `obi`, `obi_peripherals`.
  - Checks: `bender sources` passes under 0.27.4 (container) and 0.32.0 (host), and 0.27.4 leaves the lock byte-identical.
  - `tech_cells_generic` stays 0.2.13 (the tested set).
- [x] 2.3 **[eda]** Run `make ig-hw-all` from a clean `.bender/`. Verify:
  - It exits 0.
  - `hw/cheshire_bootrom_split.sv` regenerates with `BOOTROM_NUM_PARTS=2`.
  - Its size and part count are compared against the 1.1 reference, and any difference is explained by the bootrom source diff.

  Done (after 2a). `ig-hw-all` and `pickle-all` exit 0 from a fresh `.bender/` in the derived image. The bootrom was recompiled from Cheshire v0.3.1's `cheshire_bootrom.S/.c` and split into 2 parts. The split file keeps its size (242137 B) because the ROM image is fixed-size, and its contents differ from the reference starting at line 52, as the bootrom source diff predicts.

## 2a. Tooling image: Python modules the new RTL generators need (added during apply)

- [x] 2a.1 **[edit]** Add `flatdict` to `docker/all/requirements.txt`. Verify: a post-bump `make ig-hw-all` failed in `newt-eda:dev` with `ModuleNotFoundError: No module named 'flatdict'` from iDMA's `gen_idma.py`, and the same run passes once `flatdict` is installed.
      Confirmed both ways. Without it: `idma.mk:116` fails generating `idma_transport_layer_rw_axi.sv`. With it (runtime `pip install` probe): `ig-hw-all` + `pickle-all` exit 0. `flatdict` is the only new module needed.
- [x] 2a.2 **[edit]** Add `python3 -c "import <mod>"` assertions to `docker/smoke-test.sh` for `hjson mako yaml tabulate flatdict`, and add the `eda-tooling-image` spec delta. Verify: against the current `:dev` (2026-09-17) only `python3 import flatdict` FAILs. Against a thin image that replays `docker/all/Dockerfile`'s pip step with the new `requirements.txt` (`newt-eda:bump-cheshire`, local), all 20 checks pass and the smoke test exits 0.
- [x] 2a.3 **[eda]** On the PR, `docker-image.yml` builds the real image and its smoke test passes. Verify: the PR run is green, `:pr-N` is published, and the synth-lane dispatch in 6.2 uses `image_tag=pr-N`.
      **Split into prerequisite PR #49 (user decision, 2026-09-27).** #48's required `sw` check failed with `No module named 'flatdict'`: the fast lane runs in `:dev`, and Cheshire's sw build also generates iDMA register headers with `gen_idma.py`. The earlier claim that the fast lane was unaffected was wrong. So the three image files (`requirements.txt`, `packages.txt`, `smoke-test.sh`) land first in #49. After it merges and `:dev` republishes, #48 is rebased onto `main` (the files drop out of its diff) and its CI re-runs. The `eda-tooling-image` spec delta stays here.
      Verified on the real images. The `docker-image.yml` runs succeeded for both #48 (`36309653503`) and #49 (`36310349683`), including the new `sgdisk` and Python-import smoke checks. `ghcr.io/wortexx/newt-eda:pr-48` is published, and the synth lane was dispatched against it (run `36321657267`).

## 3. Repair dependency-keyed flow artifacts

- [x] 3.1 **[edit]** In `target/ihp13/yosys/project-synth.mk`, rename the keep-hierarchy selector `"*/gen_dma.i_dma"` → `"*/gen_dma.i_idma"`. Verify: `grep -n 'gen_dma.i_idma' target/ihp13/yosys/project-synth.mk` hits, and `gen_dma.i_dma"` has no hits.
- [x] 3.2 **[eda]** Run `make pickle-all`, then sweep every rule in `target/ihp13/pickle/patches/{morty,svase,sv2v}` against the stage input it targets (design D3):
  - sed rules: `sed -n '/<pattern>/p' | wc -l`
  - patches: `patch --dry-run`

  Verify: a table in this task's notes lists each rule/patch with its match count or hunk result, before (1.1 pickles) vs after.

  Done. How each result was established:
  - *Sed rules*: the rule's match count on the regenerated raw stage input, cross-checked by whether the rule's replacement text appears in the flow's final output.
  - *Patches*: `patch --dry-run` on the raw input, plus the flow log.

  | Rule / patch | Before (`main`) | After (v0.3.1) | Cause |
  |---|---|---|---|
  | `morty.sed` r1 `axi_llc` `req_q` store pattern | fires (1) | fires (1) | — |
  | `morty.sed` r2 `slib_mv_filter` header | fires (1) | **0: module gone** | apb_uart 0.2.1→0.2.3 no longer contains `slib_mv_filter` |
  | `morty.sed` r3 CVA6 ID-map `default:` | fires (1) | **0: text rewritten** | Cheshire now emits `'{default: DefaultMapEntry}` |
  | `sv2v.sed` r1 `for (…; i < advance; …);` | **0** | **0** | pre-existing: the 6 sv2v loops have no trailing `;`, so the rule never matched |
  | `sv2v.sed` r2 reset address `64'h…2000000` | fires (1) | fires (1) | — |
  | `svase.sed` `RegOut.num_out` | fires | fires | reg packages unchanged |
  | `clic_implicit_enum_cast`, `hyperbus_w2phy_forloops`, `intr_routed_indexing`, `serial_link_ddr_in_ff`, `wt_axi_adapter2` | apply | apply (larger offsets only) | — |
  | `SlinkMaxClkDiv_renaming` | applies (fuzz 2) | applies (fuzz 2) | — |
  | `wt_axi_adapter.patch` | **3/3 FAILED** | **3/3 FAILED** | pre-existing (see 1.1): targets an older CVA6, superseded by `wt_axi_adapter2` |
  | `protocol_e_axi_renaming.patch` | applies | **1/1 FAILED** | iDMA 0.6 rewrote `protocol_e` (6 members with explicit values) |

  In both runs the pickle completes (sv2v exit 0) with the failing patches skipped.
- [x] 3.3 **[edit]** Resolve the `cva6_id_map_t` `default:` sed rule in `morty.sed` per design D4. The mechanism is to delete the rule if the new `'{default: DefaultMapEntry}` passes svase+sv2v unmodified, else re-target it. Verify: `make pickle-all` exits 0, and the 3.2 sweep shows the rule is either gone or matches exactly one line.
  Done. The rule is deleted. `make pickle-all` exits 0 without it, the new `'{default: DefaultMapEntry}` form passes svase and sv2v, and the Yosys front-end replay (see 3.5) accepts it.
- [x] 3.4 **[edit]** Fix or delete every other rule/patch that 3.2 found non-matching (spec: "Text-keyed pickle patches match the pinned design"). Verify: re-running the 3.2 sweep shows zero sed rules with 0 matches, and zero rejected hunks.
  Done, with two decisions made with the user during apply.

  Retargeting or deleting what the bump broke:
  - `protocol_e_axi_renaming.patch`: deleted. iDMA 0.6 rewrote the enum, and sv2v and the Yosys front end accept it unrenamed.
  - `morty.sed` `slib_mv_filter`: kept. It fires again because apb_uart is held at 0.2.1 (design D6).

  Rules that were already dead on `main`, deleted per design D7: `wt_axi_adapter.patch`, `sv2v.sed` `i < advance`.

  Re-sweep on the final tree:
  - Every sed rule matches: `morty.sed` 1 + 1, `sv2v.sed` 1.
  - `svase.sed`'s single rule is evidenced indirectly, with an identical signature before and after: 9 `RegOut.num_out` in, 0 out, 12 × `8'd14`.
  - Every patch applies (7 hunks' worth, offsets and fuzz only).
  - Zero `.rej` files, and the build log contains no `FAILED`.
- [x] 3.5 **[eda]** Check every `YOSYS_KEEP_HIER_INST` instance selector (non-`t:` entries) against the svase pickle's instance names. Verify: each resolves to ≥1 instance, recorded as a list in this task's notes (spec: "Dependency-keyed flow selectors match the pinned design").

  Done. The check replays `yosys_synthesis.tcl` up to `hierarchy -check -top iguana_chip` (liberty + `read_verilog -sv` of the pickle + the keep-hierarchy loop, with `select -count`) on the final pickle, in yosys 0.69. Results:
  - `FRONTCHECK_OK`.
  - All 24 selectors match at least 1 object, including `*/gen_dma.i_idma` = 1.
  - `*/gen_clic.i_clic` matched 0 on both sides (CLIC disabled), so it was deleted per D7.

  This check also caught what the pickle alone would have hidden. apb_uart 0.2.3's OBI UART fails `read_verilog` with `2nd expression of procedural for-loop is not constant!`, which led to design D6.
## 4. Simulation and software

- [x] 4.1 **[eda]** Run `make ig-sw-all`. Verify: it exits 0 and `helloworld.spm.elf` is produced.
  Done, on the image with `gdisk` added. `ig-sw-all` exits 0 and produces `helloworld.spm.elf` and 10 test ELFs (9 on `main`).

  The first attempt failed with exit 127 on `helloworld.gpt.bin`. iDMA 0.6's `idma.mk` sets `SHELL := /bin/bash`, and under bash Cheshire's `sgdisk … &> /dev/null` really runs. On `main`, `/bin/sh` backgrounds the command and silently drops the missing `sgdisk`. Per the user's decision, `gdisk` goes into `docker/all/packages.txt`, with an `sgdisk --version` smoke check and the `eda-tooling-image` delta.
- [x] 4.2 **[eda]** Run Questa `make ig-sim-rtl` with `helloworld.spm.elf` (BOOTMODE 0 / PRELMODE 0). If `vip_cheshire_soc`'s parameters/ports changed, adapt `target/sim/src/fixture_iguana.sv`. Verify: "Hello World!" and an EOC return code of 0 appear in the transcript. If Questa is unavailable in this environment, record that, and 4.3 becomes the only sim gate.
  **Done with Xcelium instead of Questa (user decision, 2026-09-28).** Questa is not available.
  - **Functional evidence.** The functional check is the `xcelium-sim-lane` change's VM round trips (its tasks 3.1–3.3 and 5.6, Xcelium 24.03). They ran on the post-bump RTL: Cheshire v0.3.1 plus the fork's address-map-only patch, `v0.3.1-newt.1`, driven by v0.3.1's `vip_cheshire_soc`. Results:
    - `helloworld.spm` passes (JTAG halt → preload → resume, `Hello World!`, exit 0).
    - `dma_2d` passes, which exercises the iDMA 0.6 wrapper.
    - `spm_uncached` passes, which exercises the uncached-SPM remap that was dead code at the old pin.
    - `DMSTATUS` behaves correctly throughout.
    - The AXI-RT and CLIC tests time out because those units are disabled in `CheshireCfg`, a configuration fact.
  - **Current `main` is covered.** It has the same RTL as the bundle that passed (`5ec4197`), so no new VM run was needed.
  - **`fixture_iguana` itself is not compiled**, because its hyperram vendor model is unavailable. Instead its `vip_cheshire_soc` hookup (`.*` plus 7 named parameters) was checked statically against the VIP header at both Cheshire revisions:
    - One parameter was added, `UseDramSys`, which defaults to 0 and is not needed.
    - The I2C and SPI ports changed from `logic` to `wire`.
    - No port was added or removed.

    So the fixture's by-name hookup is unchanged.
- [x] 4.3 **[eda]** Run `make ig-sim-verilator` with `helloworld.spm.elf`. Verify: the model builds. Record whether the 3.1 debug-module symptom in `verilator-sim-flow` (stuck `DMSTATUS`) changes. This change neither requires nor claims a fix. Add a one-line note to `verilator-sim-flow/tasks.md` 3.1 with the outcome.
  Done, with a pre-existing limitation. The model **does not build on either side**, and `main` fails identically with Verilator 5.050 in the current `:dev`: `%Error: Internal Error: ../V3Number.h:242` at CVA6 `wt_axi_adapter.sv:139`, the negative-width replication `{{CVA6Cfg.AxiAddrWidth-riscv::PLEN{1'b0}}, …}`. That makes it CVA6 plus Verilator and independent of this bump. As a result, the stuck-`DMSTATUS` symptom could not be compared. The outcome is noted in `verilator-sim-flow/tasks.md` 3.1.
- [x] 4.4 **[eda]** Run `verilator --lint-only` over `hw/iguana_*.sv` with the new `bender script verilator` flist, the same invocation the fast-lane `lint` job uses. Verify: exit 0, with no new `%Error` compared to the pre-bump lint.

  Done. The bump broke it at first: 5 %Errors per file from iDMA 0.6's `idma_generated.sv` (`REG_BUS`). The fix is the `ci.yml` lint step change (design D8, approved during apply). The real step body, extracted from `ci.yml`, gives 0 %Errors for every module of all four `hw/*.sv` files on both `main` and the bump tree, and a planted syntax error still fails it.
## 5. Docs and cross-change notes

- [x] 5.1 **[edit]** Update `AGENTS.md`'s dependency-changes constraint to say that upstream IP is pinned by released `version:`, with the lock giving exactness, and that forks are pinned by `git`/`rev`. Verify: the section renders and matches the `rtl-dependencies` spec's first requirement.
- [x] 5.2 **[edit]** In `docs/infra-plan.md`, record the bump: old/new pin, the known silent-drop fixes (selector, sed rule, plus anything 3.2 found), and the sim outcomes from 4.2/4.3. Verify: the entry names both commit SHAs.
  Done: `docs/infra-plan.md` gains **Phase 13**, a phase-ordering line and a section. The section names both full commit SHAs and records the lock policy, the apb_uart hold, every silent-drop fix, the Yosys front-end check, the image and CI-lint changes, the sw/sim outcomes (Questa not run; Verilator failing identically on `main`), the behavioural changes, and follow-ups. The synth-lane metrics line stays open for 6.2.
- [x] 5.3 **[edit]** Add a short note to `openspec/changes/replace-svase-sv2v-with-read-slang/proposal.md` saying its Cheshire fork should branch from `v0.3.1`, and saying whether 3.3 showed the `cheshire_pkg` assignment-pattern fix is already upstream. Verify: the note references this change by name.

  Done. The note covers the fork base, the likely-moot `cheshire_pkg` fork fix (re-run the spike on v0.3.1 first), the shrunk patch set, and revisiting the apb_uart hold once slang is in.

  That proposal is untracked in the working tree, not on `main`, so the note stays local and is **not** committed on this change's branch. Whoever owns that change picks it up.
## 6. Integration

- [x] 6.1 **[edit]** Open the PR. Verify: the fast-lane `lint` (including `bender sources`) and `sw` jobs are green.
  Done: PR #48, merged as `f3fe9bb`. The first CI run failed `sw` on `:dev` (no `flatdict`), so the image files were split into prerequisite PR #49, merged as `9133185`. #48 was then rebased, and its `lint`, `sw` and stub jobs went green on the republished `:dev`.

- [x] 6.2 **[long]** Run the synth lane against the PR. It is triggered by `workflow_dispatch` of `synth.yml` on the PR branch with `image_tag=pr-48`, not by the `full-synth` label: a label-triggered run uses `:dev`, which lacks `flatdict`, and would fail in `ig-hw-all`. Verify:
  - The lane completes with a clean yosys `CHECK`.
  - The cell count, area, DFF count and WNS deltas against `synth-baseline.json` are copied into `docs/infra-plan.md`'s entry from 5.2, with the expected causes noted (iDMA 0.6.3, the extra CVA6 execute region, the live SPM remap).
  - `synth-baseline.json` is reseeded only as a deliberate, separately stated step.

  This task is non-blocking for merge if the lane is unavailable. Record that instead.
  Done. [Run 36321657267](https://github.com/wortexx/newt/actions/runs/36321657267) on `:pr-48`: all stages passed, yosys `CHECK` reported 0 problems, and `synth-all` + STA took about 2 h.
  - **VM start.** The run stayed queued until the synth VM was started by hand (`az vm start -g newt-synth-lane-rg -n newt-synth-runner`), as `synth.yml` note (1) describes for synth-only sessions. The day's scheduled `main` run ([36306162671](https://github.com/wortexx/newt/actions/runs/36306162671), pre-bump `599d837`) took the runner first. That run reproduces `synth-baseline.json` exactly, which confirms the flow is deterministic, and it serves as the same-day baseline.
  - **Metrics**, `main` vs this change:

    | Metric | `main` | v0.3.1 | Δ |
    |---|---|---|---|
    | Cells | 735,953 | 735,837 | −116 (−0.02%) |
    | Chip area | 17,774,827.51 µm² | 17,776,378.83 µm² | +1,551.32 µm² (+0.01%) |
    | DFFs | 89,499 | 89,209 | −290 (−0.32%) |
    | WNS | unavailable | unavailable | pre-existing `basilisk.sdc` pattern issue |

  - **Baseline not reseeded.** `eda-tooling-image` reserves reseeding for synthesis-*tool* bumps, and this drift is negligible.
