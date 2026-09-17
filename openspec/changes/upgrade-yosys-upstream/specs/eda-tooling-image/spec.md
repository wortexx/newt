# eda-tooling-image — delta spec

## MODIFIED Requirements

### Requirement: Image toolchain contents

The `newt-eda` image SHALL be built on `ubuntu:24.04` and SHALL contain, on `PATH`, all tools needed by the pickle/synth flow plus the new simulation/lint tools:

- **Synthesis**: upstream `YosysHQ/yosys` at the **v0.69** release tag (no fork, no local patches), built with its bundled ABC and with the built-in slang SystemVerilog frontend (`read_slang`) available, so the Phase 8 frontend work can load it without a plugin.
- **Pinned, unchanged from the 2024 image**: morty `v0.9.0`, svase `f5f5290`, sv2v `v0.0.11`, bender `v0.27.4`.
- **Bumped**: OpenROAD at a tagged release from 2025 or later; riscv64 bare-metal GCC ≥ 13 with binutils ≥ 2.40 (so `-march=rv64gc_zknh` compiles).
- **New**: Verilator v5.x (stable release) and Verible (lint + format binaries).
- **Flow-support utilities the Makefiles call by name, not just the EDA tools themselves**: `gawk` (yosys.mk's and openroad.mk's log-timestamping pipelines pipe through `gawk '{ print strftime(...), $0 }'` - a plain POSIX `awk` does not have `strftime`) and `unzip` (OpenROAD's `checkpoint.tcl` save/load flow). Found missing from the image only by actually running `make synth-all` against it (`gawk`) and grepping the flow scripts (`unzip`) - version-checking the EDA tools alone does not catch a missing support utility the flow silently depends on.

#### Scenario: All tools present and at required versions

- **WHEN** `yosys --version`, `morty --version`, `svase --help` (svase's own `--version` throws an unhandled `cxxopts` exception before reaching its version-print path - a pre-existing bug in that pin, not something this change touches), `sv2v --version`, `bender --version`, `openroad -version`, `riscv64-unknown-elf-gcc --version`, `verilator --version`, `verible-verilog-lint --version`, `gawk --version`, and `unzip -v` are run inside the image
- **THEN** each command exits 0 and reports the pinned or minimum version above, and `yosys --version` reports `0.69`

#### Scenario: Yosys ships the features the synthesis script depends on

- **WHEN** `yosys -p 'help abc'` and `yosys -p 'help read_slang'` are run inside the image
- **THEN** both exit 0, the `abc` help lists the `-liberty_args` option, and `read_slang` is a known command without loading any plugin

#### Scenario: Zknh toolchain support

- **WHEN** a C file is compiled inside the image with `riscv64-unknown-elf-gcc -march=rv64gc_zknh`
- **THEN** compilation succeeds (no "unknown extension" error)

### Requirement: Image runs the existing synthesis flow at parity

The image SHALL run the repository's frontend + synthesis flow (`make ig-hw-all`, `make pickle-all`, `make synth-all`) on unmodified Basilisk to completion. Whenever a synthesis-tool bump is adopted, the result SHALL be compared against the checked-in synthesis baseline (`target/ihp13/yosys/synth-baseline.json`) produced by the previous tool, the delta SHALL be explained before adoption, the resulting netlist SHALL remain consumable by the backend scripts' instance and net name patterns, and the baseline SHALL be reseeded from the new tool once adopted so that later design changes are measured against the tool that synthesizes them.

#### Scenario: Adoption gate on unmodified Basilisk

- **WHEN** `make synth-all` completes in the new image on unmodified Basilisk RTL
- **THEN** the run finishes without errors, yosys `CHECK` reports 0 problems, and cell count / chip area / DFF count are recorded and diffed against the checked-in `synth-baseline.json`, with the delta explained (tool-version change is an acceptable explanation only when the direction and magnitude are consistent with the tool's own release notes) before adoption

#### Scenario: Netlist naming stays compatible with the backend scripts

- **WHEN** the gate's netlist is produced by the new synthesis tool
- **THEN** every instance and net name pattern that the backend constraints and macro-placement scripts match (`target/ihp13/openroad/src/basilisk_instances.sdc`, `target/ihp13/openroad/scripts/macros*.tcl`, and the `*_reg` clock-pin lookup in `chip.tcl` / `pnr/common.tcl`) resolves to at least one object in the new netlist, or the pattern is updated in the same change

#### Scenario: Baseline reseeded after adoption

- **WHEN** the adoption gate passes and the new image becomes the default flow environment
- **THEN** `synth-baseline.json` is regenerated from the gate run's metrics, recording the image tag and yosys version it came from, so the synth lane's drift summary on the next unmodified-RTL run reports zero drift

#### Scenario: Fallback to the previous image

- **WHEN** the new image fails the adoption gate or a regression is traced to the tool bump
- **THEN** the flow remains runnable with the previous published `newt-eda` image by its immutable `<yyyy-mm-dd>-<sha>` tag (recorded in `synth-baseline.json` and `docs/infra-plan.md`), and the synth lane can be pointed at that tag with a one-line change

#### Scenario: Fallback to the 2024 image

- **WHEN** a regression cannot be isolated to a single tool bump and the previous `newt-eda` tag is not enough to bisect it
- **THEN** the 2024 `pulp-iguana` image remains reachable through the documented legacy pull target (`make -C docker pull-legacy`) as the deepest fallback, with its reference kept in `docker/Makefile`
