# CI P&R Lane (self-hosted Azure agent)

## Why

Synthesis is now covered nightly (Phase 4), but nothing exercises the OpenROAD backend: `chip.tcl` has never been run against the new image's OpenROAD (`2c56926`, vs. the 2024 `589dee1c8` it was written for — Phase 1 explicitly deferred the estimated 2–3 day API port), and the stock script is known not to complete unattended even on the old version (`remove_buffers` segfaults ~1/3 runs; post-route `repair_timing -repair_tns 100` loops forever on a design that can't close timing). Until a P&R lane exists, any coprocessor RTL change can silently break floorplan/place/CTS/route, and the thesis's silicon-realistic PPA numbers have no reproducible, automated path. The one piece of prior art for an unattended flow — `resume_no_repair_timing.tcl` from the manual end-to-end run — was lost with the cleaned-up `backend-run/` directory and must be rebuilt.

This change touches: **backend** (OpenROAD flow scripts) and **CI** (new workflow + Azure lifecycle automation). No RTL, sim, synth-flow, or sw changes.

## What Changes

- **Unattended P&R flow** (backend): adapt the OpenROAD flow to the new OpenROAD command APIs and restructure it so it completes without a human: `remove_buffers` wrapped with one retry, `repair_timing` bounded (`-repair_tns 20 -max_buffer_percent 15`) or skipped, checkpoint-resume structure preserved. Success is gated through `global_route`; `detailed_route` runs bounded/best-effort and its non-convergence is reported, not fatal (known congestion-bound at 63% utilization).
- **New workflow `.github/workflows/pnr.yml`** (CI): triggers = weekly cron + `workflow_dispatch` + tags/releases; `pnr` job on the existing self-hosted Azure VM (`newt-synth-runner`, label `self-hosted-synth`), `timeout-minutes: 2880`; reuses the synth lane's fork-PR posture (no PR trigger at all here, so the surface is smaller).
- **VM lifecycle automation** (CI/Azure): GH-hosted `start` job (`az vm start`) and `stop` job (`if: always()`, `az vm deallocate`), authenticated via an **OIDC federated credential pulled forward from Phase 6** (user-assigned managed identity created manually via `az` CLI — no stored secrets, no Terraform yet). This automation absorbs/supersedes the manual 10:00 UTC auto-shutdown backstop, which would otherwise kill every multi-hour P&R run mid-flight; a replacement cost backstop that doesn't murder live runs is part of the design.
- **Artifact policy**: DEF + reports + logs → GitHub artifacts; checkpoints (~1.5 GB × ~13) → Azure Blob (storage account created manually for now) with a 30-day lifecycle rule.
- **Coexistence with the synth lane**: the single runner serializes jobs; the design must ensure the P&R `stop` job cannot deallocate the VM out from under a queued/running synth-lane job, and the nightly synth cron queuing behind a 2-day P&R run is an accepted, documented interaction.

## Capabilities

### New Capabilities

- `pnr-flow`: what the unattended OpenROAD place-and-route flow must do — run to completion without interaction on the new OpenROAD version, bound or skip the non-converging repair steps, checkpoint each stage, gate success through global route, and treat detailed route as best-effort.

### Modified Capabilities

- `ci-pipeline`: adds the P&R lane requirements — when it runs (weekly/dispatch/tags, never per-PR), VM start/deallocate lifecycle around the job with OIDC auth and no long-lived secrets, artifact/checkpoint publication targets and retention, non-gating status (never a required check), and non-interference with the synth lane sharing the same runner.

## Impact

- **New/changed code**: `target/ihp13/openroad/scripts/` (adapted `chip.tcl` and/or a new unattended flow script + retry wrapper), `.github/workflows/pnr.yml`, possibly small `openroad.mk` additions for CI entry points.
- **Azure resources** (manual for now, Phase 6 formalizes): user-assigned managed identity + federated credential scoped to `wortexx/newt` workflows, storage account + container + lifecycle rule, removal/supersession of the existing VM auto-shutdown. Cost profile changes from "manual stop/start discipline" to "deallocated by default, billed per run" — the plan's original ~$50–150/mo estimate finally becomes realistic.
- **Existing synth lane**: `synth.yml` untouched functionally, but its documented operational note (VM up = nightly runs) changes once the VM is deallocated by default — its header comment and `docs/infra-plan.md` need updating to match the new lifecycle reality.
- **Not changed**: yosys fork, pickle chain, RTL, `ci.yml` fast lane, Questa targets. Phase 6 IaC (Terraform/Bicep, Packer image, budget alerts) stays future work — this change does the minimum by hand and documents it.
