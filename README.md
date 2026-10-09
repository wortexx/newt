# Newt

Newt is a master's thesis project that adds SHA-3 (Keccak) cryptography instructions to a Linux-capable RISC-V SoC. It carries them through a fully open-source flow (Yosys + OpenROAD) on IHP's [130nm BiCMOS Open Source PDK](https://github.com/IHP-GmbH/IHP-Open-PDK), so the power, performance and area figures come from silicon that could actually be fabricated, not from simulation estimates.

The work has two arms:

- **Instruction-set extension (ISE).** Five custom instructions (`kclr`, `kxor`, `krd`, `shatr`, `kperm`) run in a Keccak coprocessor attached to the CVA6 core through its CV-X-IF eXtension interface. The core RTL stays unmodified. See [`hw/coproc/README.md`](hw/coproc/README.md).
- **Memory-mapped accelerator.** A Keccak block on the SoC's AXI bus, driven by the CPU or by the DMA engine. It serves as the comparison point for measuring where an ISE beats an accelerator, and where it doesn't.

Both arms are verified against the NIST SHA-3 test vectors on the full SoC and compared with pinned software baselines (XKCP, riscv-crypto). They are then measured through synthesis and place-and-route. The results are in [`docs/results/sha3-evaluation.md`](docs/results/sha3-evaluation.md), the thesis plan in [`docs/custom-isa-extension.md`](docs/custom-isa-extension.md), and the CI/infrastructure plan in [`docs/infra-plan.md`](docs/infra-plan.md).

## A fork of Basilisk

Newt is a fork of [Basilisk](https://github.com/pulp-platform/cheshire-ihp130-o) (`pulp-platform/cheshire-ihp130-o`), an end-to-end open-source Linux-capable SoC built on the [Cheshire](https://github.com/pulp-platform/cheshire) toolkit and part of the [PULP (Parallel Ultra-Low-Power) platform](https://pulp-platform.org/). Basilisk provides the SoC, its IHP 130nm implementation and the open EDA flow. Newt adds the SHA-3 hardware, a refreshed toolchain image, open-source and Xcelium simulation lanes, and CI that runs synthesis and place-and-route. Upstream has been dormant since 2024-10, so this fork maintains its own tooling.

Names inherited from upstream are kept on purpose. Basilisk was initially developed under the name *Iguana*, so the top-level design is `iguana_chip` and most make targets use an `ig-` prefix. Internally the project name is still `basilisk` (`PROJ_NAME`/`RTL_NAME`), because many scripts and paths depend on it.


## Disclaimer

This project is still under active development; some parts may not yet be fully functional, and existing interfaces, toolflows, and conventions may be broken without prior notice. We target a stable release as soon as possible.


## License

Unless specified otherwise in the respective file headers, all code checked into this repository is made available under a permissive license. All hardware sources and tool scripts are licensed under the Solderpad Hardware License 0.51 (see `LICENSE`). All software sources are licensed under Apache 2.0.



## Tools

### Docker

As long as you do not want to tinker with the tools, the easiest setup is with the docker image.

1. [Install Docker](https://docs.docker.com/engine/install/)
   1. Optional but recommended: [Docker as non-root user](https://docs.docker.com/engine/install/linux-postinstall/)
2. [Install docker-compose](https://docs.docker.com/compose/install/)
3. clone repository
4. in the repo-root, execute `./use-docker.sh`

### Local install

Make sure the following tools are installed.
Then check `tools.mk`, it contains the paths to all tools. They either need to be in the `PATH` or set directly.

- [Bender](https://github.com/pulp-platform/bender#installation): Dependency manager
- [Morty](https://github.com/pulp-platform/morty#install): SystemVerilog pickler
- [SVase](https://github.com/pulp-platform/svase#install--build): SystemVerilog pre-elaborator
- [SV2V](https://github.com/zachjs/sv2v#installation): SystemVerilog to Verilog
- [Yosys](https://github.com/YosysHQ/yosys#building-from-source): Synthesis tool; upstream v0.69, pinned in `docker/yosys/Dockerfile`.
- [OpenRoad](https://github.com/The-OpenROAD-Project/OpenROAD/blob/master/docs/user/Build.md): Backend tool

The following tools are only required to build software and simulate the design:
- riscv64-unknown-elf-gcc
- Modelsim

Additionally the following python packages are required:
```bash
# requirement from register_interface
pip3 install hjson Mako PyYAML setuptools tabulate

# memory and cpu profiler (optional)
pip3 install procpath
```

### Claude Code agents/skills (optional)

If you use Claude Code, run `make apm` after cloning to install the agents,
skills, and rules declared in `apm.yml` (regenerated from `apm.lock.yaml`,
not committed to git).



## Quick Start

Project-specific documentation lives in [`docs/`](docs/): the thesis plan, the CI/infrastructure plan, the P&R pipeline, the architecture decision records and the results. For the underlying SoC, the [Cheshire Documentation](https://pulp-platform.github.io/cheshire/) gives a good overview.

```bash
# download RTL, generate register-files, configure units
make ig-hw-all
# pickle to Verilog
make pickle-all
# Yosys synthesis (~2h on yosys v0.69; needs >35 GB RAM, swap if less)
make synth-all
# OpenRoad backend (>24h)
make backend-all
# SoC power of a synthesized netlist, no P&R needed (~25 min; see the target's
# comment in target/ihp13/openroad/openroad.mk and docs/infra-plan.md Phase 17)
make soc-power-probe NETLIST=<path>/basilisk.yosys.v

# build Cheshire test software
make ig-sw-all
# prepare for simulation
make ig-sim-all
# run simulation, select one in [...] and optinally add -gui
make ig-sim-[rtl/sv2v/synth](-gui)

# or simulate with the open-source Verilator flow instead of Questa
# (see target/verilator/README.md - status, plusargs, what is/isn't simulated)
make ig-sim-verilator
```

## Flow
```mermaid
graph LR;
	Bender-->Morty;
	Morty-->SVase;
	SVase-->SV2V;
	SV2V-->yosys;
	yosys-->OpenRoad;
```
1. Bender provides a list of SystemVerilog files
2. These files are pickled into one context using Morty
3. The pickled file is simplified using SVase
4. The simplified SystemVerilog code is run through SV2V
5. This gives us synthesizable Verilog which is then loaded into yosys
6. In yosys the Verilog RTL goes through various passes and is mapped to the technology cells
7. The netlist, constraints and floorplan are loaded into OpenRoad for Place&Route

## CI and infrastructure

The CI lanes run on GitHub Actions, partly on a self-hosted Azure VM:

| Lane | Workflow | Runs on |
| --- | --- | --- |
| Fast lane (lint, sw, coprocessor unit sim + block synth; SoC sim still a stub) | `.github/workflows/ci.yml` | GitHub-hosted |
| Full synthesis | `.github/workflows/synth.yml` | Self-hosted Azure VM |
| Place & route | `.github/workflows/pnr.yml` | Self-hosted Azure VM |
| Idle-VM watchdog | `.github/workflows/vm-watchdog.yml` | GitHub-hosted |
| Infra validation | `.github/workflows/infra.yml` | GitHub-hosted |

The Azure resources behind the self-hosted lanes — the VM and its network, the
OIDC identity, the checkpoint storage account, the Key Vault and the cost
budget — are declared in Bicep under [`infra/azure/`](infra/azure/).
**[`infra/azure/README.md`](infra/azure/README.md) is the authoritative
description**: how to deploy, how to rebuild the runner host from scratch, how
to rotate the runner registration credential, and how to check for drift.

Planning and rationale live in [`docs/infra-plan.md`](docs/infra-plan.md); the
P&R flow itself is described in [`docs/pnr-pipeline.md`](docs/pnr-pipeline.md).
