# Spec Delta

## MODIFIED Requirements

### Requirement: Image toolchain contents

The `newt-eda` image SHALL be built on `ubuntu:24.04` and SHALL contain, on `PATH`, all tools needed by the pickle/synth flow plus the new simulation/lint tools:

- **Synthesis**: upstream `YosysHQ/yosys` at the **v0.69** release tag (no fork, no local patches), built with its bundled ABC and with the built-in slang SystemVerilog frontend (`read_slang`) available, so the Phase 8 frontend work can load it without a plugin.
- **Pinned, unchanged from the 2024 image**: morty `v0.9.0`, svase `f5f5290`, sv2v `v0.0.11`, bender `v0.27.4`.
- **Bumped**: OpenROAD at a tagged release from 2025 or later; riscv64 bare-metal GCC ≥ 13 with binutils ≥ 2.40 (so `-march=rv64gc_zknh` compiles).
- **New**: Verilator v5.x (stable release) and Verible (lint + format binaries).
- **Flow-support utilities the Makefiles call by name, not just the EDA tools themselves**: `gawk` (yosys.mk's and openroad.mk's log-timestamping pipelines pipe through `gawk '{ print strftime(...), $0 }'` - a plain POSIX `awk` does not have `strftime`) `unzip` (OpenROAD's `checkpoint.tcl` save/load flow), and `sgdisk` from `gdisk` (Cheshire's `sw.mk` builds GPT test images with it; since iDMA 0.6's `idma.mk` sets `SHELL := /bin/bash` for the whole make run, a missing `sgdisk` fails `make ig-sw-all` instead of being silently backgrounded by `/bin/sh`). Found missing from the image only by actually running `make synth-all` against it (`gawk`) and grepping the flow scripts (`unzip`) - version-checking the EDA tools alone does not catch a missing support utility the flow silently depends on.
- **Python modules the flow's RTL generators import during `make ig-hw-all`**: `hjson`, `mako`, `yaml` (PyYAML) and `tabulate` (register_interface / OpenTitan `regtool`), and `flatdict` (iDMA 0.6's `gen_idma.py`, pulled in by Cheshire v0.3.1). Like the support utilities above, a missing module is invisible to tool version checks and only fails hardware generation partway through a run.

#### Scenario: All tools present and at required versions

- **WHEN** `yosys --version`, `morty --version`, `svase --help` (svase's own `--version` throws an unhandled `cxxopts` exception before reaching its version-print path - a pre-existing bug in that pin, not something this change touches), `sv2v --version`, `bender --version`, `openroad -version`, `riscv64-unknown-elf-gcc --version`, `verilator --version`, `verible-verilog-lint --version`, `gawk --version`, `unzip -v`, and `sgdisk --version` are run inside the image
- **THEN** each command exits 0 and reports the pinned or minimum version above, and `yosys --version` reports `0.69`

#### Scenario: Yosys ships the features the synthesis script depends on

- **WHEN** `yosys -p 'help abc'` and `yosys -p 'help read_slang'` are run inside the image
- **THEN** both exit 0, the `abc` help lists the `-liberty_args` option, and `read_slang` is a known command without loading any plugin

#### Scenario: Zknh toolchain support

- **WHEN** a C file is compiled inside the image with `riscv64-unknown-elf-gcc -march=rv64gc_zknh`
- **THEN** compilation succeeds (no "unknown extension" error)

#### Scenario: Flow Python modules importable

- **WHEN** `python3 -c "import <module>"` is run inside the image for each of `hjson`, `mako`, `yaml`, `tabulate` and `flatdict`
- **THEN** each import exits 0
