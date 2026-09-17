# AGENTS.md

Guidance for coding agents (Claude Code or any other AGENTS.md-reading tool)
working in this repo. It summarizes and links to the authoritative docs below
rather than duplicating them — when in doubt, follow the linked source.

## Project overview

**newt** is a master-thesis fork of [Basilisk](https://github.com/pulp-platform/cheshire-ihp130-o)
(`pulp-platform/cheshire-ihp130-o`), an end-to-end open-source Linux-capable
RV64 SoC built on the [Cheshire](https://github.com/pulp-platform/cheshire)
toolkit with a CVA6 host core, targeting IHP's SG13G2 130nm open-source PDK
through a fully open EDA flow (Yosys + OpenROAD). Basilisk was initially
developed under the name *Iguana*, so the top-level design is `iguana_chip`
and most scripts/Makefiles use `ig-`/`iguana` prefixes, while the project name
in docs and most other places is `basilisk`.

The thesis goal is to add SHA cryptography instructions to CVA6 — either via
a CV-X-IF coprocessor or the RISC-V `Zknh` standard extension (decision
pending) — and carry them end-to-end through the real synthesis/P&R flow to
get silicon-realistic PPA (power/performance/area) numbers on real, fabricable
IHP silicon. See [`docs/custom-isa-extension.md`](docs/custom-isa-extension.md)
for the full thesis plan and [`docs/infra-plan.md`](docs/infra-plan.md) for
the CI/infrastructure plan (a living document — check it for current phase
status before assuming something described there is finished).

Upstream (`pulp-platform/cheshire-ihp130-o`) has been dormant since 2024-10;
this fork owns all tooling decisions going forward rather than expecting
upstream fixes.

## Tool setup

### Docker (recommended unless you need to modify the tools themselves)

1. [Install Docker](https://docs.docker.com/engine/install/) and
   [docker-compose](https://docs.docker.com/compose/install/)
2. From the repo root: `./use-docker.sh`

This pulls `ghcr.io/wortexx/newt-eda:dev` (see [`docker/README.md`](docker/README.md))
and drops you into a shell with every tool below already on `PATH`.

### Local install

Install these tools, then check [`tools.mk`](tools.mk) — it lists the exact
binaries the Makefiles expect on `PATH` (or set their paths directly):

- [Bender](https://github.com/pulp-platform/bender#installation) — dependency manager
- [Morty](https://github.com/pulp-platform/morty#install) — SystemVerilog pickler
- [SVase](https://github.com/pulp-platform/svase#install--build) — SystemVerilog pre-elaborator
- [SV2V](https://github.com/zachjs/sv2v#installation) — SystemVerilog to Verilog
- [Yosys](https://github.com/YosysHQ/yosys#building-from-source) — synthesis (upstream v0.69, pinned in `docker/yosys/Dockerfile`)
- [OpenROAD](https://github.com/The-OpenROAD-Project/OpenROAD/blob/master/docs/user/Build.md) — place & route backend
- `riscv64-unknown-elf-gcc` and Modelsim/Questa — only needed to build software and simulate

Python packages: `pip3 install hjson Mako PyYAML setuptools tabulate` (required
by `register_interface`), plus optionally `pip3 install procpath` for memory/CPU
profiling.

### Claude Code agents/skills (optional)

Run `make apm` after cloning to install the Claude Code agents, skills, and
rules declared in `apm.yml` (pinned in `apm.lock.yaml`, not committed to git —
see the `agent-tooling` spec at
[`openspec/specs/agent-tooling/spec.md`](openspec/specs/agent-tooling/spec.md)).

## Command reference

The flow: `Bender → Morty → SVase → sv2v → Yosys → OpenROAD`, driven by
Makefiles (`iguana.mk`, `tools.mk`, `target/ihp13/*.mk`).

```bash
# hardware: download RTL, generate register-files, configure units
make ig-hw-all

# pickle: flatten SystemVerilog to synthesizable Verilog
make pickle-all

# synth: Yosys synthesis (~2.5 h, needs >35 GB RAM — see "Expensive targets" below)
make synth-all

# backend: OpenROAD place & route (>24 h — see "Expensive targets" below)
make backend-all

# software: build Cheshire test binaries
make ig-sw-all

# simulation: prepare, then run one of rtl / sv2v / synth (Questa-based), optionally with -gui
make ig-sim-all
make ig-sim-rtl        # or ig-sim-sv2v / ig-sim-synth, each with an optional -gui suffix

# or the open-source, Questa-free Verilator flow instead
# (see target/verilator/README.md for status/plusargs/coverage — not yet
# passing end-to-end as of this writing)
make ig-sim-verilator
```

`make ig-all` runs the Cheshire hardware + full simulation chain in one shot.
`iguana.mk` is the authoritative list of `ig-*` targets if this reference
drifts from it.

### Expensive targets — do not run speculatively

- `make synth-all`: ~2.5 hours, needs >35 GB RAM (swap if less). Don't kick
  this off just to "see if it works" — check with the user first.
- `make backend-all`: >24 hours, and the design does not close timing in the
  open flow today (WNS ≈ −2.5 ns, known/accepted — see
  [`docs/infra-plan.md`](docs/infra-plan.md) for the current, possibly worse,
  measured figure). Never treat backend as a per-change validation gate.

## Repo layout

| Path | What |
| --- | --- |
| `hw/` | Top-level SystemVerilog sources (`iguana_chip`, `iguana_soc`, `iguana_pkg`) |
| `target/ihp13/` | IHP13-specific synth/backend flow (Yosys, OpenROAD scripts) |
| `target/sim/`, `target/verilator/` | Questa and Verilator simulation setups |
| `docker/` | Multi-stage `newt-eda` tooling image (pickle, yosys, openroad, riscv64) |
| `scripts/` | Standalone Python utilities (bootrom split, bisect/verify helpers) |
| `docs/` | Living planning docs: thesis plan, CI/infra plan, P&R pipeline reference |
| `infra/azure/` | Bicep IaC for the self-hosted CI VM, identity, storage, budget (see its own README) |
| `openspec/` | OpenSpec change proposals/specs — planning artifacts for both infra and RTL work |
| `.github/workflows/` | CI lane definitions (see below) |
| `Bender.yml` / `Bender.lock` | Pinned RTL dependencies (`cheshire`, `cva6`, `axi`, `hyperbus`, `register_interface`) |
| `iguana.mk`, `tools.mk`, `apm.mk` | Top-level Makefile includes |

## CI lanes

| Lane | Workflow | Runs on |
| --- | --- | --- |
| Fast lane (lint, sw, sim stubs) | `.github/workflows/ci.yml` | GitHub-hosted |
| Full synthesis | `.github/workflows/synth.yml` | Self-hosted Azure VM |
| Place & route | `.github/workflows/pnr.yml` | Self-hosted Azure VM |
| Idle-VM watchdog | `.github/workflows/vm-watchdog.yml` | GitHub-hosted |
| Infra validation | `.github/workflows/infra.yml` | GitHub-hosted |
| Tooling image build | `.github/workflows/docker-image.yml` | GitHub-hosted |

The Azure resources behind the self-hosted lanes (VM, network, OIDC identity,
checkpoint storage, Key Vault, budget) are declared in Bicep under
[`infra/azure/`](infra/azure/); **[`infra/azure/README.md`](infra/azure/README.md)
is the authoritative description** of how to deploy, rebuild the runner host,
rotate credentials, and check for drift. Planning and rationale live in
[`docs/infra-plan.md`](docs/infra-plan.md); the P&R flow itself is described in
[`docs/pnr-pipeline.md`](docs/pnr-pipeline.md).

## Hard constraints

- **Naming**: `PROJ_NAME`/`RTL_NAME` must stay `basilisk` — many scripts and
  paths (e.g. `basilisk.sdc`, checkpoint/report paths) hardcode it. Do not
  rename, even though the design is internally called `iguana_chip`.
- **Dependency changes**: `cheshire` and `cva6` are modified via forks pinned
  in `Bender.yml` (by `git`/`rev`), not via local patches — prefer a fork
  commit over anything beyond a one-line change.
- **Yosys is upstream**, pinned to a release tag in
  `docker/yosys/Dockerfile` (v0.69 since 2026-09; the custom fork it
  replaced is retired). Bump the tag only via a change that re-runs the
  synthesis adoption gate — a version bump moves cell count, area and
  netlist naming, so it needs a measured before/after and a reseeded
  `target/ihp13/yosys/synth-baseline.json`, not just a green build.
- **Licensing**: hardware and tool scripts are Solderpad Hardware License
  0.51; software is Apache-2.0. Keep SPDX headers consistent with the
  existing file's license family when editing, and add one to new
  hardware/script files (see any existing `.sv`/Makefile header for the
  format).
- **CVA6 config** is `cv64a6_imafdcsclic_sv39`; CV-X-IF exists on the core
  but is disabled/tied off (`CvxifEn = 0`) until the thesis work enables it.
