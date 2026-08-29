# eda-tooling-image — delta spec

## Purpose

Defines the project-owned `newt-eda` container image: the toolchain contract every flow stage and CI lane runs against — which tools and versions it must contain, how it is named, tagged, and published, how it is rebuilt when its sources change, and what must be proven before the project adopts it as the default flow environment.

## ADDED Requirements

### Requirement: Image toolchain contents

The `newt-eda` image SHALL be built on `ubuntu:24.04` and SHALL contain, on `PATH`, all tools needed by the pickle/synth flow plus the new simulation/lint tools:

- **Pinned, unchanged from the 2024 image**: yosys from the `phsauter/yosys` fork at commit `3ce5059`, morty `v0.9.0`, svase `f5f5290`, sv2v `v0.0.11`, bender `v0.27.4`.
- **Bumped**: OpenROAD at a tagged release from 2025 or later; riscv64 bare-metal GCC ≥ 13 with binutils ≥ 2.40 (so `-march=rv64gc_zknh` compiles).
- **New**: Verilator v5.x (stable release) and Verible (lint + format binaries).
- **Flow-support utilities the Makefiles call by name, not just the EDA tools themselves**: `gawk` (yosys.mk's and openroad.mk's log-timestamping pipelines pipe through `gawk '{ print strftime(...), $0 }'` - a plain POSIX `awk` does not have `strftime`) and `unzip` (OpenROAD's `checkpoint.tcl` save/load flow). Found missing from the image only by actually running `make synth-all` against it (`gawk`) and grepping the flow scripts (`unzip`) - version-checking the EDA tools alone does not catch a missing support utility the flow silently depends on.

#### Scenario: All tools present and at required versions

- **WHEN** `yosys --version`, `morty --version`, `svase --help` (svase's own `--version` throws an unhandled `cxxopts` exception before reaching its version-print path - a pre-existing bug in that pin, not something this change touches), `sv2v --version`, `bender --version`, `openroad -version`, `riscv64-unknown-elf-gcc --version`, `verilator --version`, `verible-verilog-lint --version`, `gawk --version`, and `unzip -v` are run inside the image
- **THEN** each command exits 0 and reports the pinned or minimum version above

#### Scenario: Zknh toolchain support

- **WHEN** a C file is compiled inside the image with `riscv64-unknown-elf-gcc -march=rv64gc_zknh`
- **THEN** compilation succeeds (no "unknown extension" error)

### Requirement: Image runs the existing synthesis flow at parity

The image SHALL run the repository's frontend + synthesis flow (`make ig-hw-all`, `make pickle-all`, `make synth-all`) on unmodified Basilisk to completion, and the result SHALL be compared against the 2024 baseline reports before the image is adopted as the default environment.

#### Scenario: Adoption gate on unmodified Basilisk

- **WHEN** `make synth-all` completes in the new image on unmodified Basilisk RTL
- **THEN** the run finishes without errors, yosys `CHECK` reports 0 problems, and cell count / area / WNS are recorded and diffed against `target/ihp13/yosys/reports/basilisk_area.rpt` from the 2024 baseline, with large deltas investigated before adoption

#### Scenario: Fallback to the 2024 image

- **WHEN** the new image fails the adoption gate or a regression is traced to the tool bumps
- **THEN** the flow remains runnable with the 2024 `pulp-iguana` image (its reference is kept documented and functional until the gate passes)

### Requirement: Image naming and publication

The image SHALL be published to GitHub Container Registry as `ghcr.io/wortexx/newt-eda`, with an immutable tag of the form `<yyyy-mm-dd>-<short-sha>` for every published build and a moving `:dev` tag pointing at the latest published build.

#### Scenario: Published build is pullable by both tags

- **WHEN** an image build is published from commit `abc1234` on 2026-09-01
- **THEN** `docker pull ghcr.io/wortexx/newt-eda:2026-09-01-abc1234` and `docker pull ghcr.io/wortexx/newt-eda:dev` both succeed and resolve to the same image digest

### Requirement: Automated rebuild on tooling changes

A CI workflow SHALL rebuild the image whenever files under `docker/**` change, publishing on pushes to `main` and build-verifying (without publish) on pull requests.

#### Scenario: Push to main rebuilds and publishes

- **WHEN** a commit touching `docker/**` lands on `main`
- **THEN** CI builds all image stages and pushes `ghcr.io/wortexx/newt-eda:<yyyy-mm-dd>-<sha>` and updates `:dev`

#### Scenario: Pull request build-verifies only

- **WHEN** a pull request modifies files under `docker/**`
- **THEN** CI builds the image and fails the check on build errors, but publishes nothing to GHCR

### Requirement: Local developer entry points use the new image

The repository's container entry points (`use-docker.sh`, `docker-compose.yml`, `docker/Makefile`) SHALL reference `ghcr.io/wortexx/newt-eda` so a developer gets the new image by default, including pulling `:dev` without building locally.

#### Scenario: Developer shell in the new image

- **WHEN** a developer runs `./use-docker.sh` on a clean checkout
- **THEN** they get an interactive shell inside `ghcr.io/wortexx/newt-eda:dev` (pulled from GHCR if not present) with the repository mounted as before
