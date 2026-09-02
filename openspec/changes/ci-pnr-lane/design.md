# Design — ci-pnr-lane

## Context

See proposal.md for motivation. Constraints that shape the approach:

- **The flow as it stands cannot run in CI.** `openroad.mk`'s `run-openroad` target invokes `openroad scripts/chip.tcl -gui` (a GUI session), and `chip.tcl` was written against OpenROAD `589dee1c8` (2024) while the image ships `2c56926` (2026) — Phase 1 recorded the expected breakages (`remove_buffers` now requires instance args; `repair_timing`/`global_route`/`detailed_route` flag changes; `save_image`/GUI changes) and budgeted 2–3 days, never spent. Appendix B of `docs/infra-plan.md` records the headless recipe (`QT_QPA_PLATFORM=offscreen`, `openroad -exit`, no `-gui`) and the post-`load_checkpoint` GRT-layer-config gotcha (`DRT-0155` otherwise).
- **Known failure modes on this design** (from the one manual end-to-end run): `remove_buffers` segfaults ~1/3 runs; post-route `repair_timing -repair_tns 100` loops effectively forever on a design with WNS ≈ −2.5 ns; `detailed_route` did not converge (700 k → 516 k DRC violations over 2 iterations, manually stopped). The prior unattended-flow prototype (`resume_no_repair_timing.tcl`) was lost with `backend-run/`; only its lessons survive in the plan.
- **Checkpoints already exist**: `checkpoint.tcl` saves `{def,v,odb}` zipped per stage (~1.5 GB each, ~13 per run) into `save/`, with `load_checkpoint` to resume. `chip.tcl` is a single linear script around them.
- **Infrastructure that exists**: one Azure VM (`newt-synth-runner` in `newt-synth-lane-rg`, `swedencentral`, `Standard_E16ds_v5`, 16 vCPU / 128 GB) with Docker and a GitHub runner labeled `self-hosted-synth`, shared with the synth lane; manual stop/start lifecycle with a **fixed 10:00 UTC auto-shutdown** that has already killed one synth run mid-flight and would kill *every* multi-day P&R run. No OIDC, no storage account, no IaC.
- Resource fit: P&R peaks ~26–30 GB RAM / ~12–32 threads (Appendix A) — comfortable on 128 GB/16 vCPU. Disk budget ~200 GB per run inc. checkpoints.
- The synth lane already earned the container-job hardening (bash default shell, `safe.directory`, `.bender` retry) — the `pnr` job reuses it verbatim where applicable.

## Goals / Non-Goals

**Goals:**

- An unattended, resumable OpenROAD flow that runs on the pinned image version and degrades informatively (bounded repairs, best-effort routing) instead of hanging or dying silently.
- Full VM lifecycle automation: deallocated is the default state; a run starts the VM, uses it, and deallocates it — replacing (not coexisting with) the fixed-time auto-shutdown.
- All Azure auth via OIDC; zero stored secrets.

**Non-Goals:**

- Timing closure or DRC convergence — the design doesn't close timing in the open flow (known/accepted); the lane measures, it doesn't fix.
- Phase 6 proper: Terraform/Bicep, Packer golden image, budget alerts. Everything Azure-side here is manual `az` commands captured in a runbook for Phase 6 to formalize.
- Changing the synth lane's behavior (its nightly-only-if-VM-up gap stays; see D8 and Open Questions).
- `save_image`/screenshot rendering in CI — nice-to-have; dropped if the new OpenROAD's GUI-offscreen path fights back.

## Decisions

### D1: Stage-per-process flow architecture, not one monolithic Tcl script

Restructure the backend flow from one linear `chip.tcl` into **one OpenROAD process invocation per stage**, driven by a shell/make driver: each stage loads the previous stage's checkpoint, does its work, saves its own checkpoint, exits. The driver (`run_pnr.sh` or make targets, decided at implementation) sequences stages, retries retryable ones, and stops at the configured gate.

Why: every robustness property the specs demand falls out of this shape, and none is achievable inside a single Tcl process:

- A `remove_buffers` **segfault kills only that stage's process**; the driver retries the stage once from the preceding checkpoint (spec: retried-not-fatal). A Tcl `catch` cannot catch a segfault.
- **Resume is free**: rerunning the driver skips stages whose checkpoint already exists (or starts from an explicitly named stage).
- The per-stage **wall-clock timeout** (`timeout(1)` in the driver) bounds any residual hang the flag-bounding misses.
- CI and human debugging use the same entry point; a human can rerun exactly one stage.

Each stage script sources a shared prologue (`init_tech` + SDC + the GRT layer config: `set_routing_layers -signal Metal2-TopMetal1 …` + the two `set_global_routing_layer_adjustment` lines) so the Appendix-B reload gotcha is structurally impossible rather than remembered-per-stage.

Stage boundaries follow `chip.tcl`'s existing checkpoints: `floorplan` (incl. power grid), `pre_place` (repair_tie + remove_buffers — its own small stage so the retry is cheap), `gpl` (placement 1 + repair + placement 2), `dpl`, `cts`, `grt`, `grt_repair`, `drt`, `final` (filler + DEF). Exact grouping may shift during bring-up; the invariant is: every group ends in a checkpoint, and `remove_buffers` sits in a cheap, retryable group.

*Alternatives considered:* (a) adapt `chip.tcl` in place, single process — keeps upstream's shape but cannot satisfy retry/timeout requirements (segfault = lose everything since the last manual intervention); (b) port to ORFS (OpenROAD-flow-scripts) — a per-stage architecture off the shelf, but a wholesale replacement of the project's tuned scripts (floorplan/power-grid/macro placement are hand-crafted per L1 config) and a much bigger diff than adapting what exists. Rejected both. Stock `chip.tcl` stays in the tree untouched for reference/local GUI use; the staged flow is new files beside it reusing its per-stage content.

### D2: Repair bounding — configuration, not surgery

- Pre-route repairs (gpl/cts stages) keep their existing bounded forms (`-repair_tns 70/90`) — they completed in the manual run.
- The post-GRT repair stage (`grt_repair`) runs `repair_timing` **bounded per the plan: `-repair_tns 20 -max_buffer_percent 15`** (both setup and hold variants), replacing the `-repair_tns 100` calls that looped forever. A driver-level knob (`PNR_SKIP_GRT_REPAIR=1`) skips the stage entirely, mapping to the plan's "skipped or bounded".
- Flag names get re-validated against the new OpenROAD during bring-up (D3); the bound values are the contract, the spelling may change.

### D3: API adaptation is validated stage-by-stage on the real VM before any CI wiring

Bring-up order: get each stage running manually (dispatch-free — SSH + the long-lived-container pattern from Appendix B item 5) against the netlist the synth lane already produces on that VM, stage by stage, fixing API breaks as they surface. Only when `floorplan → grt` passes end-to-end does workflow wiring start. This keeps the 2–3-day (or worse) uncertain part off the CI critical path and means the first `workflow_dispatch` run is a confirmation, not an experiment.

### D4: Gate = `floorplan → grt`; everything after is best-effort

The driver exits 0 iff all stages through `grt` complete. `grt_repair`, `drt`, and `final` run afterwards as best-effort: their failure or non-convergence is captured in the run summary (DRC-violation trajectory from `_route_drc.rpt`, iteration count, which stage stopped) but doesn't change the exit code. `detailed_route` runs with a bounded iteration budget (`-droute_end_iter`, value picked during bring-up — stock 40 ran "many hours" without converging; something like 8–16 plus the 48 h job timeout bounds it twice) and a driver timeout as the backstop. This is the user-selected success bar and matches the plan's "clean route is a stretch goal, not a gate".

### D5: Workflow shape — `pnr.yml` with start / pnr / upload / stop jobs

- **Triggers**: `schedule` (weekly, one cron), `workflow_dispatch`, `push: tags: ['**']`. **No `pull_request` trigger at all** — the fork-PR problem the synth lane had to gate (its design D1b) is designed out entirely; only trusted refs reach the runner.
- **`start`** (GH-hosted): OIDC login → `az vm start` (idempotent if already running).
- **`pnr`** (`runs-on: [self-hosted, self-hosted-synth]`, `needs: start`, `container: newt-eda:dev`, `timeout-minutes: 2880`): checkout → synth-lane hardening steps → obtain the netlist (D7) → run the staged flow driver → write step summary → upload DEF/reports/logs artifacts (`if: always()`, 30-day retention).
- **`upload-checkpoints`** (`runs-on` same runner, **no container**, `needs: pnr`, `if: always()`): `az login` via OIDC using the VM host's az CLI (added to VM provisioning runbook), `az storage blob upload-batch` of `save/*.zip` to `pnr-checkpoints/<run_id>/`. Runs outside the container because the image doesn't ship az CLI and shouldn't (it's an EDA image); the runner workspace is host-visible so the files are reachable. *Alternative:* VM's own managed identity via IMDS — works, but splits auth into two mechanisms; OIDC everywhere is one story and satisfies the spec as written.
- **`stop`** (GH-hosted, `needs: [pnr, upload-checkpoints]`, `if: always()`): the guarded deallocate — see D6.
- **Concurrency**: one group for the whole workflow, `cancel-in-progress: false`. Opposite of the synth lane's choice, deliberately: cancelling a multi-day P&R run to start a newer one throws away days of paid compute; the single runner serializes anyway, and GH holding at most one pending run per group is acceptable at weekly cadence.
- The job fails/succeeds exactly on the driver's exit code (spec: job status follows the flow's gate).

### D6: Guarded deallocate + idle watchdog replaces the fixed auto-shutdown

Two cooperating pieces, both GH-hosted, both OIDC:

1. **`stop` job guard**: before `az vm deallocate`, query GitHub for activity on the runner: `gh api repos/{repo}/actions/runners` (busy flag) and in-progress/queued runs of `synth.yml`/`pnr.yml`. If anything is running or queued, **skip deallocation** (log why, exit 0 — leaving the VM up for the other job is the correct outcome, and the watchdog is the eventual cleanup). Deallocation *attempt* failure, by contrast, fails the job loudly (spec: cost leak must be visible).
2. **`vm-watchdog.yml`**: hourly scheduled GH-hosted job — if the VM is running AND the runner is idle AND no runs are queued, deallocate. This is the cost backstop that replaces the 10:00 UTC auto-shutdown; unlike it, it never fires while a job is live. It also sweeps the synth lane's manual-start usage (a VM started by hand for a synth run now gets turned off afterwards automatically — strictly better than today's discipline).
3. **The Azure fixed auto-shutdown is deleted** only after the watchdog has been observed doing its job (sequencing in tasks.md) — never a window with no backstop at all.

Race window (watchdog checks just as a job is being assigned): narrowed by checking queued runs too, accepted as residual — worst case a just-starting run finds the VM deallocating and its `start` job (or a manual restart) recovers it. A scheduled GH cron can drift/skip (documented GH behavior); acceptable for a backstop whose worst-case miss costs hours of idle VM, not correctness.

*Alternative considered:* on-VM systemd idle-checker — no GH API dependency, but invisible from the repo, drifts from any future golden image, and is exactly the kind of hand-configured VM state Phase 6 wants to eliminate. Rejected.

### D7: The pnr job synthesizes its own netlist (self-contained), reusing the synth lane's steps

The P&R run needs `basilisk.yosys.v` for the revision under test. Reaching into a previous synth-lane run's artifact creates a stale-input hazard (the exact problem the synth lane's "pickle is never stale" requirement exists to prevent) and an awkward cross-workflow artifact dependency. So the `pnr` job runs `ig-hw-all → pickle-all → synth-all` itself (~3 h of its 48 h budget, on a VM class that's already proven to do it nightly) before entering the staged flow. Weekly cadence makes the duplicated 3 h cheap; correctness is trivially guaranteed.

*Alternative considered:* download the newest `basilisk-netlist` artifact matching the ref — faster but wrong-by-default on tags/dispatch refs the synth lane never built.

### D8: OIDC via a GitHub environment-scoped federated credential

Manual `az` setup (runbook'd for Phase 6): user-assigned managed identity `newt-ci-identity`; federated credential whose subject is pinned to a GitHub **environment** (`azure`) rather than per-ref subjects — tags and dispatch refs would otherwise each need their own credential (Azure federated credentials match subjects exactly; the environment-scoped subject is constant across all of them). The `start`/`stop`/`upload-checkpoints`/watchdog jobs declare `environment: azure`; the `pnr` job itself needs no Azure access. Role assignments, minimal: Virtual Machine Contributor scoped to the VM resource (start/deallocate), Storage Blob Data Contributor scoped to the checkpoint container. No subscription-level roles (spec: bounded scope).

**Correction found during task 1.1's real setup (2026-09-02):** the subject this design assumed - `repo:wortexx/newt:environment:azure` - is not what GitHub actually presents. This repo has stable/immutable OIDC subject claims in effect, so the real subject embeds numeric owner and repository IDs: `repo:wortexx@177997/newt@1350544657:environment:azure` (confirmed via `gh api users/wortexx` and `gh api repos/wortexx/newt`, and via the literal subject a failed token exchange reported). The federated credential was created with the plain form, failed a live test with "No matching federated identity record found", then was corrected with `az identity federated-credential update --subject "repo:wortexx@177997/newt@1350544657:environment:azure"` and re-verified passing. Anyone recreating this credential (Phase 6's IaC, a lost-and-rebuilt identity) needs the ID-embedded form, not the plain one - check the actual failed-subject error rather than assuming the plain form, since this GitHub setting isn't visible from the workflow YAML itself.

### D9: Checkpoint storage — one storage account, lifecycle rule does the retention

Storage account in `newt-synth-lane-rg` (same region as the VM — uploads are intra-region), container `pnr-checkpoints`, blobs under `<run_id>/<stage>.zip`, management-policy lifecycle rule: delete blobs >30 days. Retention enforcement lives Azure-side, not in workflow logic — a failed/cancelled workflow can't leak storage forever. LRS, cool tier (write-once, rarely read). Cost at steady state (~4 runs × ~20 GB retained): ~$1–2/mo — noise next to VM compute.

### D10: Documentation truth-maintenance

`synth.yml`'s header (manual-lifecycle note, 10:00 UTC auto-shutdown references, "don't dispatch after 06:30 UTC" note) and `docs/infra-plan.md` Phase 5 are rewritten to the new reality: VM deallocated by default, started by `pnr.yml` or by hand, watchdog cleans up, auto-shutdown gone. The synth lane's nightly cron still only fires usefully when the VM is up — unchanged behavior, now stated in terms of the watchdog world.

## Risks / Trade-offs

- **[OpenROAD API port exceeds the 2–3 day estimate, or `2c56926` has new failure modes on this design]** → D3's stage-wise manual bring-up surfaces this early and incrementally; checkpoints mean no lost work between attempts. If a specific stage is intractable on the new version, fallback options in order: pin that stage's known-good flags, consult ORFS's current-API usage as a cheat-sheet, or (last resort) run the backend from the legacy 2024 image (`pull-legacy`) while the port continues — lane ships gated on whichever path works.
- **[`grt` itself fails under the new OpenROAD (gate unreachable), not just `drt`]** → same mitigation as above; additionally the gate is driver configuration, so a temporarily narrower gate (through `cts`) can ship first with the spec-gap explicitly tracked, rather than shipping nothing. Spec change would be required — do not do this silently.
- **[stop-job guard races: deallocate lands while a new run's job is being assigned]** → guard checks busy + queued; residual window accepted — recovery is the next run's `start` job or a manual start; never data loss (checkpoints are on disk/blob).
- **[Watchdog cron doesn't fire (GH schedule drift/outage) and the stop guard skipped deallocation]** → worst case is idle-VM hours at $1.216/h until the next hourly tick lands; Phase 6's budget alert is the eventual belt-and-suspenders. Accepted.
- **[VM disk fills across weekly runs (~200 GB/run budget)]** → pnr job starts with a workspace/save-dir cleanup step (previous run's checkpoints are in Blob by then); runbook records the disk size check. **Confirmed real during task 1.4's check (2026-09-03), not just theoretical**: the root filesystem - where Docker's image cache and the GitHub runner's job workspace both live - has only ~111G free, below the ~200GB/run budget. The VM's much larger local disk (`/mnt`, ~560G free) is Azure's ephemeral temp disk and does not survive a deallocate, so it can't safely hold anything that needs to persist across this design's own start/deallocate cycle (the runner's registration, Docker's pulled image). User decision (task 1.4): accept the risk for now rather than resize the OS disk or remap the runner's workspace to `/mnt`; revisit if a real run in task 2.4/3.2 actually hits ENOSPC. If it does, resizing the OS disk (requires a deallocate/resize/restart cycle) is the lower-risk fix - it doesn't touch the already-registered runner's configuration, unlike remapping `_work` to `/mnt`.
- **[48 h timeout expires mid-`drt`]** → by then `grt` completed, so the gate verdict stands; `drt`'s partial DRC reports and all checkpoints up to it are uploaded by the `if: always()` jobs. The run reads as its true result, not as mystery-cancelled.
- **[Weekly P&R and nightly synth contend for the one runner]** → accepted and specified: jobs queue; synth waits (up to ~2 days worst case) — at this repo's activity level that's a report delayed, not work blocked. Revisit (second runner label or second VM) only if it actually hurts.
- **[`basilisk.sdc`'s `*ddr_rcv_clk_o*` bug (deferred from ci-synth-lane) trips `read_sdc` in the backend too]** → unlike the synth lane, P&R *needs* the SDC; if the pattern errors under the new OpenROAD's `read_sdc`, fixing that one stale cell-pattern line becomes in-scope here (it's a P&R-blocking bug now, exactly the condition the deferral named) — small, contained, recorded in tasks.

## Migration Plan

Order matters for the safety/cost backstops:

1. Azure setup first (identity, federated credential, storage) — inert until used.
2. Flow bring-up manually on the VM (D3) — VM lifecycle still manual + old auto-shutdown active throughout (bring-up sessions are attended, runs between 10:00 UTC shutdowns or with the shutdown skipped by hand for a long stage).
3. Wire `pnr.yml`; first `workflow_dispatch` end-to-end run with the old auto-shutdown still present but *disabled for that window by hand* (48 h run vs. 10:00 UTC daily is a guaranteed kill otherwise).
4. Land `vm-watchdog.yml`; observe one correct idle-deallocate.
5. Delete the Azure auto-shutdown; enable the weekly cron; update `synth.yml` header + `docs/infra-plan.md`.

Rollback: re-create the auto-shutdown (`az vm auto-shutdown`), disable the weekly cron — the VM is back to today's manual regime; flow scripts are additive files and stock `chip.tcl` was never touched.

## Open Questions

- Exact weekly cron slot (assumption: Friday ~18:00 UTC so the run owns the weekend and clears before Monday activity) and the `drt` iteration budget — both tuned freely after the first real runs; neither changes specs or approach.
- Whether the synth lane should later gain its own `start` job (making nightly synth real every night at ~$110/mo VM cost) — a deliberate cost decision for the user once the OIDC plumbing exists; out of scope here.
- Whether `report_image`/`save_image` survives the new OpenROAD headless — kept if trivial, dropped from CI stages if not (Non-Goal).
