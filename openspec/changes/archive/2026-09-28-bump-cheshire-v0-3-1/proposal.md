# Proposal

## Why

`Bender.yml` pins Cheshire to a raw commit, `4a270af` (2024-07-05), which is older than Cheshire's first tagged release. Upstream Basilisk froze there and went dormant, so the pin has never moved. The latest release is `v0.3.1` (2025-06-16, commit `5c76406`). Doing the bump now has three benefits:

- **It picks up real fixes.**
  - The LLC's uncached-SPM address remap in `cheshire_soc.sv` is dead code at the current pin. The comparison `addr & ~Mask == Base & ~Mask` parses as `addr & (~Mask == Base) & ~Mask`, which is always 0.
  - The CVA6 debug `ExceptionAddress` moves from `0x808` to `0x810` relative to the debug module.
  - The CVA6 ID-remap default gets a well-formed assignment pattern.
- **Later fork work starts from a released base.** `replace-svase-sv2v-with-read-slang` plans to move a `cheshire_pkg` assignment-pattern fix into a Cheshire fork. The thesis work may also need Cheshire forks for CV-X-IF un-tying. Forking from `v0.3.1` is better than forking from an untagged 2024 commit.
- **It is cheap today, because the diff that reaches the design is small.** Cheshire changed 73 files, but in `hw/` only these are touched: `cheshire_pkg.sv` (36 lines), `cheshire_soc.sv` (36 lines), the new `cheshire_idma_wrap.sv`, and the bootrom. The `cheshire_soc` port list is unchanged. The register-file packages are unchanged. The CVA6 pin (`pulp-v1.0.0`) is byte-identical. The cost grows as more fork work lands on top of the old pin.

## What Changes

- `Bender.yml`: `cheshire` changes from `rev: 4a270af…` to `version: 0.3.1`. `Bender.lock` is re-resolved.
- Shared transitive dependencies move up to Cheshire v0.3.1's floor:
  - axi 0.39.2 → 0.39.6
  - register_interface 0.4.4 → 0.4.5
  - common_cells → ≥ 1.38.0
  - iDMA 0.5.1 → 0.6.3
  - apb_uart: *held* at 0.2.1, not Cheshire's 0.2.3 (see below)
  - axi_rt alpha.7 → alpha.10
  - new packages from Cheshire's tested set: `dram_rtl_sim` 0.1.1, `obi` 0.1.7, `axi_stream` 0.1.1

  The project's own direct pins for `axi` and `register_interface` are raised to match, so the root pins no longer sit below what Cheshire requires.
- The Yosys keep-hierarchy selector `*/gen_dma.i_dma` in `target/ihp13/yosys/project-synth.mk` is renamed to `*/gen_dma.i_idma`. Upstream renamed the instance (`dma_core_wrap i_dma` → `cheshire_idma_wrap i_idma`). A selector that matches nothing does not raise an error, so without the rename the DMA would be flattened silently.
- The morty-stage sed rule `default: return '{default: '{0, 0}};` in `target/ihp13/pickle/patches/morty/morty.sed` is re-targeted or retired. Upstream rewrote that line to `'{default: DefaultMapEntry}`, so the rule no longer matches anything. Which of the two it becomes depends on whether the pickle toolchain accepts the new form.
- Every other text-keyed pickle patch (`svase/*.patch`, `morty/*.patch`, `*.sed`) is re-checked against the new pickle. `apply-patches` ignores failed hunks (`-patch`), so a stale patch disappears without any error.
- **Behavioral (SoC)**:
  - The uncached SPM alias at `0x1400_0000` now actually remaps into the SPM.
  - The debug exception entry point changes.
  - The bootrom image is rebuilt from Cheshire v0.3.1's changed bootrom sources, and `hw/cheshire_bootrom_split.sv` is regenerated through `ig-hw-bootrom-split`.
- **apb_uart held at 0.2.1** (found during apply). Cheshire v0.3.1's tested apb_uart 0.2.3 swaps in an OBI UART that Yosys's Verilog frontend cannot read. The root pins 0.2.1 with a comment, and `reg_uart_wrap`'s interface is identical in both versions. See design D6.
- **Rules that were already dead are removed** (found during apply). These are `wt_axi_adapter.patch`, `sv2v.sed`'s `i < advance` rule, and the `*/gen_clic.i_clic` selector. None of them matched on `main` before this change. Alongside them go the two rules this bump made obsolete: `morty.sed`'s CVA6 ID-map rule and `protocol_e_axi_renaming.patch`. Yosys accepts the design without either. See design D4 and D7.
- **Tooling image** (found during apply). iDMA 0.6.x, pulled in by Cheshire v0.3.1, generates part of its RTL during `make ig-hw-all` with a Python script that imports `flatdict`, and the `newt-eda` image lacks it.
  - `flatdict` is added to `docker/all/requirements.txt`.
  - `gdisk` (`sgdisk`) is added to `docker/all/packages.txt`. iDMA 0.6's `idma.mk` sets `SHELL := /bin/bash`, so Cheshire's `sgdisk … &> /dev/null` no longer silently backgrounds a missing binary, and `make ig-sw-all` (CI's `sw` job) fails without it.
  - The image smoke test gains import assertions for every Python module the flow's generators use, so a missing one fails the image build instead of a hardware-generation run.
- **CI lint step** (found during apply). iDMA 0.6's generated `idma_generated.sv` mixes packages with about 50 `REG_BUS`-ported modules. The per-file `verilator --lint-only` step passes every package file, so each of those modules became a lint root, and every `hw/*.sv` lint failed. The step now elaborates only from the linted file's own modules, each as `--top-module`. A package-only file gets a throwaway wrapper top. See design D8.
- `docs/infra-plan.md` and `AGENTS.md` record the new pin wherever they name it.

## Capabilities

### New Capabilities

- `rtl-dependencies`: how the project pins its RTL IP dependencies, which is by released tag with an exact lock. It also covers what must stay true after a dependency moves: every flow artifact keyed on a dependency's internal text or hierarchy must still match the design built from the new pin, meaning keep-hierarchy selectors and pickle-stage sed/patch rules.

### Modified Capabilities

- `eda-tooling-image`: "Image toolchain contents" adds two things: `sgdisk` to the support utilities, and the Python modules the flow's RTL generators import (including the new `flatdict`), with a scenario asserting they import. `ci-pipeline` is unchanged; its `bender sources` requirement serves as a gate for this change as-is.
  - *Merge note*: `replace-svase-sv2v-with-read-slang` also modifies this requirement. Whichever change archives second must carry the other's edit.

## Impact

**Flow stages touched**:
- **RTL**: the dependency pin and the transitive IP versions.
- **sim**:
  - The Questa `fixture_iguana` uses `vip_cheshire_soc`, which changed by 193 lines upstream.
  - The Verilator harness wraps `iguana_soc`.
  - Both need a re-run.
- **synth**: the keep-hierarchy selector, the pickle patches, and a netlist/metric drift that is expected and must be recorded against `synth-baseline.json`.
- **backend**: none expected. The macro-placement scripts do not reference the DMA.
- **CI**: the fast lane's `bender sources` and the lint jobs exercise the new lock.
- **sw**: the bootrom sources change, and the test binaries are rebuilt against Cheshire v0.3.1's `sw/`.
- **CI lint**: the `ci.yml` lint step's elaboration roots (design D8).
- **tooling image**: `flatdict` in `docker/all/requirements.txt`, `gdisk` in `docker/all/packages.txt`, plus smoke-test assertions. The PR's `docker-image.yml` run publishes `:pr-N`, and `:dev` updates on merge.

**Code**: `Bender.yml`, `Bender.lock`, `target/ihp13/yosys/project-synth.mk`, `target/ihp13/pickle/patches/**`, `docker/all/{requirements,packages}.txt`, `docker/smoke-test.sh`, `.github/workflows/ci.yml`, and docs. The files `hw/iguana_*.sv` are expected to stay unchanged:
- `iguana_pkg`'s explicit VGA 5/6/5 override already matches the new upstream default.
- `iguana_soc` uses only the unchanged `cheshire_soc` ports and `cheshire_cfg_t` fields.

**Interacting changes**:
- `replace-svase-sv2v-with-read-slang` (proposal only). It should rebase its Cheshire fork plan onto v0.3.1, and one of its three fork fixes may already be upstream.
- `verilator-sim-flow` (blocked at 3.1 on a stuck debug-module read). The debug-address fix is worth re-testing against, but this change does not claim it fixes that blocker.
