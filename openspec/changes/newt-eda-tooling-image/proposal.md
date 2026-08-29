# newt-eda tooling image

## Why

The project's entire EDA flow runs inside the upstream `phsauter/pulp-iguana` Docker image, last built 2024-08-22 by a now-dormant upstream. It lacks a free simulator (Verilator) — the critical-path blocker for RTL CI — ships a mid-2024 OpenROAD (source of all observed backend instability), and its riscv64 GCC predates `Zknh` support, which would foreclose the standard-extension option for the thesis ISA work. We own the tooling now; Phase 1 of `docs/infra-plan.md` is to produce our own `newt-eda` image that every later phase (Verilator flow, CI lanes, Azure P&R) builds on.

**Flow stages touched:** tooling/CI only. No RTL, simulation-flow, synthesis-script, backend-script, or software changes — the flow Makefiles and scripts are exercised only as validation that the new image still runs them.

## What Changes

- Rebase the existing `docker/` multi-stage build (`pickle`, `yosys`, `openroad`, `riscv64`, `all`) from `almalinux:8.9` to `ubuntu:24.04`; port each `packages.txt` from yum to apt.
- Bump **OpenROAD** from commit `589dee1c8` to a recent tagged release.
- Bump the **riscv64 toolchain** to GCC ≥ 13 / binutils ≥ 2.40 (keeps the `Zknh` option open).
- **Keep pinned** (do not touch): yosys fork `phsauter/yosys@3ce5059`, morty `v0.9.0`, svase `f5f5290`, sv2v `v0.0.11`, bender `v0.27.4`.
- **Add new tools**: Verilator (v5.x stable) and Verible (lint/format).
- Rename/republish the image as `ghcr.io/wortexx/newt-eda` with immutable `<yyyy-mm-dd>-<sha>` tags plus a moving `:dev` tag; update `docker/Makefile`, `docker-compose.yml`, and `use-docker.sh` accordingly.
- New GitHub Actions workflow: rebuild and push the image on any `docker/**` change.
- **Adoption gate**: run `make synth-all` on unmodified Basilisk in the new image and diff cell count / area / WNS against the 2024 baseline (`target/ihp13/yosys/reports/basilisk_area.rpt`); keep the 2024 image available as a fallback.

Not breaking by design: the old image remains usable as fallback until the adoption gate passes.

## Capabilities

### New Capabilities

- `eda-tooling-image`: the project-owned containerized EDA toolchain — what tools and versions the `newt-eda` image must contain, how it is named/tagged/published to GHCR, how it is rebuilt automatically on Dockerfile changes, and the baseline-comparison gate required before the project adopts it as the default flow environment.

### Modified Capabilities

None — this is the first capability under `openspec/specs/`.

## Impact

- `docker/{pickle,yosys,openroad,riscv64,all}/Dockerfile` and `packages.txt` — base-image swap, version bumps, two new tool stages/installs.
- `docker/Makefile` — image name `phsauter/pulp-iguana` → `ghcr.io/wortexx/newt-eda`, new build targets for Verilator/Verible.
- `docker-compose.yml`, `use-docker.sh` — image-name references.
- `.github/workflows/` — new image build-and-publish workflow (first CI workflow in the repo; branch protection's required-checks list can pick it up later).
- Downstream risk: the OpenROAD bump is expected to need 2–3 days of `chip.tcl` adaptation to newer command APIs — that adaptation is **out of scope here** (it lands with the backend work); this change only has to prove the synth path (`make synth-all`) against baseline.
