## 1. Gather source content (plain editing/reading, no EDA tools)

- [x] 1.1 Extract the project/thesis overview from README.md and docs/custom-isa-extension.md and verify the summary in AGENTS.md doesn't contradict either source
- [x] 1.2 Extract tool setup steps (Docker path via use-docker.sh, local install list in README.md, tools.mk) and verify every tool/package listed there is reflected
- [x] 1.3 Enumerate the `make ig-*` command reference from iguana.mk and README.md's Quick Start (hw, pickle, synth, backend, sw, sim, including `make ig-sim-verilator` and target/verilator/README.md's not-yet-passing status) and verify every command in the Quick Start block appears
- [x] 1.4 Capture the CI lanes table and infra pointers from README.md's "CI and infrastructure" section (workflow files, self-hosted vs GitHub-hosted, links to infra/azure/README.md and docs/infra-plan.md) and verify the lane list matches the current `.github/workflows/*.yml` files on disk

## 2. Write AGENTS.md

- [x] 2.1 Draft the root `AGENTS.md` with sections: project overview, tool setup, command reference (grouped by flow stage), repo layout, CI lanes, and hard constraints (PROJ_NAME/RTL_NAME stays `basilisk`; cheshire/cva6 changes go through forks pinned in Bender.yml, not local patches; SPDX headers; Solderpad 0.51 for hw/scripts, Apache-2.0 for sw) and verify the file exists at the repo root and renders as valid Markdown
- [x] 2.2 Explicitly flag the cost/duration of `make synth-all` (~2.5h, >35GB RAM) and `make backend-all` (>24h, known WNS ~-2.5ns) as targets not to run speculatively, and verify both figures match docs/infra-plan.md
- [x] 2.3 Link out to (rather than duplicate) infra/azure/README.md, docs/infra-plan.md, and docs/pnr-pipeline.md for their respective authoritative detail, and verify AGENTS.md contains no restated detail that could drift from those files independently

## 3. Validate

- [x] 3.1 Run `openspec validate add-agents-md --strict` (or the equivalent store-scoped command) and verify it passes
- [x] 3.2 Proofread AGENTS.md end-to-end for a fresh-agent read-through and verify no command shown is copy/paste-wrong (cross-check each `make` target name against iguana.mk/apm.mk)
