# Post-merge CI verification (infra-plan Phase 9)

## Why

`ci-pnr-lane` merged to `main` on 2026-09-13 (PR #17) with six acceptance items deliberately deferred to `docs/infra-plan.md` Phase 9, all for one GitHub-side reason: a workflow's `schedule` and `workflow_dispatch` triggers are only registered once the file exists on the default branch, so none of them could be exercised from the feature branch. The bring-up ran entirely off `pnr-bringup-*` tag pushes. Two of those items carry real cost exposure until they are closed — the Azure fixed auto-shutdown is disabled-but-not-deleted (an undeclared resource the `azure-infrastructure` spec explicitly carves out), and the watchdog's `Deallocate idle VM` step has never executed even though it is now the only automatic cost backstop besides `pnr.yml`'s own `stop` job. The synth lane's nightly schedule is still `disabled_manually` from bring-up. This change closes Phase 9 in full: observe each deferred mechanism working on the real infrastructure, then remove the interim safety net and correct every document and header that still describes the pre-watchdog world.

This change touches **CI only** (workflow files, GitHub workflow state, one Azure resource deletion, docs and specs). No RTL, sim, synth, backend flow scripts, or sw changes.

## What Changes

- **First real `workflow_dispatch` of `pnr.yml`**, exercising the `resume_from_run` input path that has never run (bring-up used tag pushes and a tracked `.github/pnr-resume-from` file). To make that cheap and repeatable, `pnr.yml`'s dispatch form gains two optional inputs that expose knobs the driver already honours: `stop_after` (→ `PNR_STOP_AFTER`) and `resume_exclude` (→ `PNR_RESUME_EXCLUDE`). `pnr-bringup-11` proved this slice-of-flow pattern works in 16 minutes, but only by temporarily editing the workflow; the inputs make it a supported path, which `docs/infra-plan.md` Phase 11 already assumes exists.
- **Observe `vm-watchdog.yml` performing a real idle-deallocate** on its hourly schedule (the OIDC login and power-state read were already observed 2026-09-13; the deallocate step itself never ran because the VM was always already off).
- **Verify the coexistence guard under a real overlap**: a synth-lane run dispatched while a P&R run holds the runner queues rather than fails, `pnr.yml`'s `stop` job leaves the VM up with a clear log line when something is still active, and the watchdog cleans up afterwards.
- **Delete the Azure DevTestLab auto-shutdown schedule** (`shutdown-computevm-newt-synth-runner`, currently `status: Disabled`) — only after the idle-deallocate has been observed, so there is never a window with no backstop. This removes the one undeclared resource from the CI resource group.
- **Confirm the weekly `pnr.yml` cron is live** (found already `active` post-merge — the plan's "enable" step turned out to be moot; the first scheduled run is Friday 2026-09-18 18:00 UTC) and **re-enable the `CI Synth Lane` schedule** (`gh workflow enable`), recording how a nightly run behaves against a VM that is now deallocated by default.
- **Documentation truth-maintenance** (ci-pnr-lane design D10, deferred as its task 5.2): `synth.yml`'s header still describes manual VM lifecycle and a 10:00 UTC auto-shutdown; `vm-watchdog.yml`'s header speaks of the auto-shutdown in the future tense; `docs/infra-plan.md` Phase 5/6/9 and `infra/azure/README.md`'s drift table carry the "one exception" clause. All are rewritten to the post-watchdog reality.

Not in scope: anything about detailed-route convergence (Phase 11), the GitHub Actions version upgrade (Phase 10), a `start` job for the synth lane (a standing cost decision, see design.md Open Questions), or any change to the P&R flow scripts or the driver.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `azure-infrastructure`: the "Every CI Azure resource is declared in versioned templates" requirement drops its documented exception for the pre-existing auto-shutdown schedule — once deleted, *every* resource in the group must correspond to a declared one.
- `ci-pipeline`: the "P&R lane runs weekly, on demand, and on tags" requirement gains a scenario for the manual dispatch's resume/stop-after inputs, so that re-running one slice of the flow against a previous run's checkpoints is a supported workflow capability rather than a temporary edit.

## Impact

- **Workflows**: `.github/workflows/pnr.yml` (two new `workflow_dispatch` inputs plumbed into existing env vars; comment updates), `.github/workflows/synth.yml` (header comment only), `.github/workflows/vm-watchdog.yml` (header comment only). No change to any job's runtime logic beyond reading the new inputs, which default to empty.
- **GitHub state**: `CI Synth Lane` schedule re-enabled. `CI P&R Lane` unchanged (already active).
- **Azure**: one resource deleted (`Microsoft.DevTestLab/schedules/shutdown-computevm-newt-synth-runner`). Nothing created or modified; the Bicep templates are untouched because the schedule was never declared.
- **Docs and specs**: `docs/infra-plan.md` (Phases 5, 6, 9; Risks), `infra/azure/README.md` (drift table and prose), `docs/pnr-pipeline.md` (dispatch inputs), the two delta specs above.
- **Cost**: the verification runs themselves — one fresh full P&R run (~$30, or $0 if the Friday scheduled run is used for it), one resume-dispatch slice (~$0.35), one dispatched synth run (~$3.60), up to one hour of idle VM to catch a watchdog tick (~$1.20). Ongoing: the now-live weekly P&R cron costs ~$30/run while `drt` is still non-convergent (Phase 11) — flagged in design.md for the user to decide on, not changed here.
