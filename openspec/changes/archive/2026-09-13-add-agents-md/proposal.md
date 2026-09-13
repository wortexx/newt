## Why

Coding agents (Claude Code and other AGENTS.md-reading tools) onboarding to this repo have no single file that explains what the project is, how to build/simulate/synthesize it, where the expensive/long-running flow stages are, and which conventions (naming, licensing, dependency pinning) must not be violated. Today that knowledge is scattered across README.md, tools.mk/iguana.mk, docs/*.md, and tribal knowledge, so an agent either re-derives it by trial and error or invokes destructive/expensive targets (multi-hour synth, >24h backend) without knowing the cost. A root-level AGENTS.md, following the AGENTS.md standard already read by Claude Code and other agent tooling, closes that gap.

## What Changes

- Add a root-level `AGENTS.md` documenting: project overview and thesis context, tool setup (Docker vs. local), the full build/sim/synth/backend command reference (`make ig-*`), repo layout, CI lanes, and hard constraints agents must respect (e.g. `PROJ_NAME`/`RTL_NAME` must stay `basilisk`; dependencies are patched via forks pinned in `Bender.yml`, not local patches; synth/backend are multi-hour/multi-GB and must not be run speculatively).
- Extend the existing `agent-tooling` capability with a requirement that the repo provide and maintain this file, since it governs how agents get set up and operate in this repo (the same concern `make apm` already covers for Claude Code assets).
- No code, build target, or CI behavior changes — this is a documentation-only change.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `agent-tooling`: adds a requirement that the repository provide a root-level `AGENTS.md` with onboarding, command-reference, and constraint content for coding agents, kept consistent with README.md/tools.mk/docs as they evolve.

## Impact

- Affected: new `AGENTS.md` at repo root. No RTL / sim / synth / backend / CI / sw flow stage is touched — this change is docs-only.
- Affected code/systems: none (no Makefile, CI workflow, or script changes).
- Dependencies: none added.
