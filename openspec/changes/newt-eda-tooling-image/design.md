# newt-eda tooling image — design

## Context

See proposal.md — Why. The current `docker/` layout is a multi-stage build: four builder images (`pickle` = bender+morty+svase+sv2v, `yosys`, `openroad`, `riscv64`) each install into `/build`, and `docker/all/Dockerfile` copies the four `/build` trees into one runner image (`phsauter/pulp-iguana:dev`, almalinux 8.9). `docker/Makefile` orchestrates the five builds; `docker-compose.yml` + `use-docker.sh` are the developer entry points. There is no CI in the repo yet. Constraints: the yosys fork and pickle-tool pins must not move; `make synth-all` needs ~35 GB RAM, so the adoption gate cannot run on standard GitHub runners.

## Goals / Non-Goals

**Goals:**

- Preserve the existing multi-stage structure and `/build` prefix convention — derive, don't rewrite.
- Every published image is reproducible from a commit (all tool versions are `ARG`-pinned; immutable date+sha tags).
- CI image builds fit GitHub-hosted runners (time and disk) via per-stage registry caching.

**Non-Goals:**

- Adapting `chip.tcl` to the new OpenROAD command APIs (lands with backend work; est. 2–3 days).
- Verilator *flow* integration (`iguana.mk` targets, testbench) — Phase 2; this change only ships the binary.
- Questa: proprietary, stays host-installed and local-only; never enters the image.
- Renaming `PROJ_NAME`/`RTL_NAME` or any flow scripts.

## Decisions

**D1 — Base image `ubuntu:24.04` for all stages.**
AlmaLinux 8 (2019-era glibc/gcc) is too old to build Verilator v5 and recent OpenROAD comfortably, and its EPEL/powertools repos are drifting. Ubuntu 24.04 ships gcc-13/clang-18, matches GitHub runner hosts, and is what OpenROAD's own `DependencyInstaller.sh` targets. Alternative — almalinux 9: viable, but no advantage and further from CI hosts. Consequence: every `packages.txt` is ported yum→apt, and one bender release asset must be checked for glibc compat (`x86_64-linux-gnu` build instead of the `almalinux8.8` asset, same v0.27.4).

**D2 — OpenROAD built from a recent tagged release, dependencies via upstream installer.**
Replace the hand-rolled boost/eigen/lemon/spdlog/swig builds with OpenROAD's `etc/DependencyInstaller.sh` at the chosen tag — the hand-rolled list tracks a 2024 dependency set and will not match a 2025+ OpenROAD. Pin `OR_COMMIT` to the newest tagged release at implementation time and record it in the Dockerfile `ARG`. Alternative — keep hand-rolled deps: high maintenance, exactly what rotted in the 2024 image.

**D3 — riscv64 toolchain from `riscv-collab/riscv-gnu-toolchain` at a ≥ 2024 release tag (GCC ≥ 13).**
Keeps the existing stage shape (configure `--prefix=/build`, bare-metal newlib, `riscv64-unknown-elf-*`). Alternative — Ubuntu's cross packages: wrong triple/multilib story for bare-metal SoC tests and pins us to distro cadence.

**D4 — Verilator as a fifth builder stage; Verible from prebuilt release binaries.**
Verilator: new `docker/verilator/` stage, source build at a v5.x stable tag (v5 builds are fast, ~10 min), installed to `/build`. Verible: upstream publishes static linux-x86_64 release tarballs — unpack into `/build/bin` inside the `all` stage rather than adding a builder stage for a Bazel build (Bazel would dominate total build time for zero benefit).

**D5 — Publish via a single GitHub Actions workflow with per-stage registry cache.**
One workflow (`docker-image.yml`): triggers on `push` to `main` and `pull_request` when `docker/**` (or the workflow file) changes, plus `workflow_dispatch`. Builds the five stages with `docker/build-push-action`, using GHCR as a buildx registry cache (`cache-from`/`cache-to` per stage) so an unchanged stage (e.g. the ~1 h riscv64 or OpenROAD build) is a cache hit and only touched stages rebuild. Publishes only on `main` pushes, with `GITHUB_TOKEN` `packages: write`. Tags computed in-workflow: `$(date +%F)-$(git rev-parse --short HEAD)` + `dev`. Alternative — build the composite image in one Dockerfile: loses per-stage cache granularity, guarantees 6 h timeout trouble on cold cache. A cold full build may still exceed a standard runner; if so, split stages across matrix jobs (each pushes its stage image, a final job assembles `all`) — the Makefile already mirrors that structure.

**D6 — Adoption gate runs outside CI, manually.**
`make synth-all` needs ~35 GB RAM / ~2.5 h — not a per-change gate (per project constraints) and not standard-runner-sized. The gate is a one-time manual run (dev box with swap, or a large runner via `workflow_dispatch` later in Phase 4) with results recorded in `docs/infra-plan.md`. CI only smoke-tests tool presence/versions (cheap, catches the common breakage).

**D7 — Old image stays reachable until the gate passes.**
`docker/Makefile` keeps the old `phsauter/pulp-iguana:dev` reference available (documented variable, e.g. `make pull IMG=legacy`), and the compose service flips to `newt-eda` only when the adoption gate is green. Rollback is a one-line revert of the image reference.

## Risks / Trade-offs

- [OpenROAD bump breaks `chip.tcl`] → Accepted and out of scope here; the gate covers the yosys synth path. Budget 2–3 days in the backend phase; 2024 image remains the fallback for full P&R runs.
- [yum→apt package porting misses a runtime lib] → The `all`-image smoke test (all `--version` checks, spec scenario 1) catches missing shared libs at build time, not at first flow use.
- [svase/morty source builds break on newer clang/gcc] → Pins stay, but the *compiler* changes with the base image. If a pinned tool fails to build on 24.04, pin the stage's compiler package (e.g. `clang-16` is available on 24.04) rather than moving the tool version.
- [Cold-cache CI build exceeds runner limits] → Per-stage registry cache (D5); escalate to matrix-per-stage jobs only if observed.
- [GHCR pull rate/auth friction for local devs] → Public package visibility on `ghcr.io/wortexx/newt-eda`; `use-docker.sh` keeps working without a token.
- [`:dev` moves under a long-running experiment] → Immutable date+sha tag recorded in flow logs; pin to it when reproducing.

## Migration Plan

1. Land Dockerfile/Makefile/workflow changes on a branch; PR build verifies image builds.
2. Merge → workflow publishes first `ghcr.io/wortexx/newt-eda:<date>-<sha>` + `:dev`. Set package visibility to public (one-time, GitHub UI).
3. Run the adoption gate (D6) against that tag; record deltas in `docs/infra-plan.md`, tick Phase 1 boxes.
4. Only then flip `docker-compose.yml`/`use-docker.sh` default to `newt-eda` (can be same PR chain, gated on step 3).
5. Rollback at any point: revert the entry-point image reference to `phsauter/pulp-iguana:dev`.

## Open Questions

- Exact OpenROAD release tag and Verilator/Verible versions — chosen at implementation time (newest stable), recorded as Dockerfile `ARG`s; does not affect specs or task breakdown.
- Whether the riscv64 build should add `--enable-multilib` — decide when Phase 7 test binaries define their exact `-march` needs; default is the current single-lib configure.
