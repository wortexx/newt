# Design — post-merge-ci-verification

## Context

See proposal.md for motivation. What matters for the approach is the live state found on 2026-09-13, after `ci-pnr-lane` (PR #17) and `azure-infra-as-code` (PR #20) merged:

- `CI P&R Lane` is `active` on `main` with its Friday 18:00 UTC cron **already live** — the `gh workflow disable` from bring-up did not survive the merge (a workflow's enabled state is per file on the default branch, and the merge introduced the file there fresh). The next scheduled run is 2026-09-18 18:00 UTC. `CI Synth Lane` is still `disabled_manually`.
- `VM Idle Watchdog` has run three times (one dispatch, two scheduled), all against an already-deallocated VM, so `Deallocate idle VM` has never executed. The auto-shutdown schedule `shutdown-computevm-newt-synth-runner` is `status: Disabled`, undeclared, and still present. The VM is deallocated.
- No `PNR_RESUME_FROM_RUN` repository variable and no `.github/pnr-resume-from` file exist, so a dispatch's `resume_from_run` input is the only resume source — the path this change must exercise.
- **The synth cache key has moved since the last checkpoints were uploaded.** PR #18 added `include apm.mk` to the root `Makefile`, which is one of the key's tracked inputs (over-inclusion accepted by design: it only costs a resynthesis). Consequences: the VM-local synth cache is cold for `main` (~3 h synth on the next fresh run), and the Blob checkpoints from `pnr-bringup-10`/`-11` carry a `synth-key.txt` that no longer matches, so the netlist-identity guard will **refuse** to resume from them. Any resume verification therefore needs a fresh run on the current key first.
- `PNR_STOP_AFTER` is honoured by `run_pnr.sh` but is not plumbed through `pnr.yml`; `PNR_RESUME_EXCLUDE` is a hard-coded empty workflow env. `pnr-bringup-11` used both only by temporarily editing the workflow on a tag.
- Every other Phase 9 precondition is met: `main` requires `lint` and `sw` only, no P&R or synth job is a required check, and neither `pnr.yml` nor `synth.yml` has a `pull_request` path that could be affected.

## Goals / Non-Goals

**Goals:**

- Observe, on the real infrastructure, each mechanism ci-pnr-lane could not exercise pre-merge, at the lowest VM cost that still produces a genuine observation.
- Remove the interim auto-shutdown safety net without ever leaving the VM with no automatic deallocation path.
- Make slice-of-flow re-runs a first-class dispatch capability so Phase 11 iteration and future verification never require editing the workflow.
- Leave every document and header describing the lifecycle consistent with what is now true.

**Non-Goals:**

- Fixing or tuning anything the runs reveal about the flow itself (`drt` convergence, `grt` iteration count, cache-key scope) — recorded, handed to Phase 11 or a follow-up.
- Changing the synth lane's lifecycle (no `start`/`stop` jobs for `synth.yml`).
- Touching the Bicep templates: the deleted schedule was never declared, so nothing changes there.

## Decisions

### D1: Two runs — one fresh full run to establish checkpoints on the current key, then a minutes-long resume slice

The resume path can only be verified against checkpoints whose `synth-key.txt` matches the dispatched ref, and no such checkpoints exist (Context). So:

- **Run A** — a full run on `main` with no inputs. Establishes a synth-cache entry and Blob checkpoints for the current key. **Preferred source: the Friday 2026-09-18 18:00 UTC scheduled run**, which costs nothing beyond the cadence the plan already committed to and doubles as the first observation of the post-merge cron actually firing. If the user wants Phase 9 closed sooner, an immediate no-input dispatch is equivalent (and then also counts as "a real `workflow_dispatch` run"). Expected: synth ~3 h (cold cache), floorplan→grt ~10.5 h, `grt_repair` skip ~2 min, `drt` ~12.5 h ending in DRT-0206 as in bringup-10, no DEF, run green. ≈ 26 h, ≈ $32.
- **Run B** — `gh workflow run pnr.yml -f resume_from_run=<A> -f resume_exclude=grt_repaired -f stop_after=grt_repair`. Restores A's checkpoints (identity guard takes the *matching* path), skips `floorplan`…`grt`, re-runs `grt_repair` (its skip path re-saves the `grt` checkpoint as `grt_repaired`, ~2 min), stops. The gate (`grt`) is satisfied via resume, so the run exits 0 without touching `PNR_GATE`. Uploads a fresh checkpoint set, exercising the whole start→restore→pnr→upload→stop lifecycle from a dispatch. ≈ 15 min, ≈ $0.35 (bringup-11's measured cost for the same shape).

Why `grt_repair` and not `drt`: it is the only post-gate stage that completes in minutes, and it is exactly the stage a stop-after-the-gate slice needs — anything earlier would stop before the gate and legitimately fail.

*Alternatives rejected:* resuming from bringup-10/-11's checkpoints — refused by the identity guard, and bypassing the guard would defeat its purpose. Dispatching on the `pnr-bringup-10` tag ref (whose key does match) — runs that tag's older workflow file, so it verifies nothing about the workflow on `main`.

### D2: `stop_after` and `resume_exclude` become `workflow_dispatch` inputs; `PNR_GATE` deliberately does not

Both inputs map 1:1 onto env vars the driver and the restore step already read (`PNR_STOP_AFTER`, `PNR_RESUME_EXCLUDE`); precedence is input, else empty. Tag and cron runs see empty values and behave exactly as today. The driver already rejects an unknown stage name loudly, so no input validation is added in YAML.

`PNR_GATE` stays fixed at `grt`. bringup-11 needed `PNR_GATE=pre_place` only because it stopped *before* the gate; that is a test-harness need, not an operational one, and exposing the gate would let a dispatch redefine what "success" means for a run whose artifacts and status look like any other. A pre-gate slice is still possible — it just reports failure, which is the honest verdict.

*Alternatives rejected:* keep editing the workflow per experiment (what bringup-11 did) — noisy commits, easy to forget to revert, and contradicts Phase 11's stated iteration model. Repository variables — cannot be set by the CI token and linger invisibly (ci-pnr-lane D11's reasoning).

### D3: Overlap test = dispatch `synth.yml` while Run A's `pnr` job holds the runner; both possible orderings are accepted outcomes

This is the spec scenario literally ("nightly synth fires during a P&R run"). The synth job queues behind the multi-hour `pnr` job. When `pnr` ends, two jobs want the runner — the queued synth job and A's own `upload-checkpoints` — and GitHub does not guarantee the order:

1. **synth first**: synth runs ~3 h, `upload-checkpoints` waits, then `stop` finds nothing active and deallocates directly. Spec-compliant (synth ran after the P&R job, VM was up for it), but the guard's *skip* branch is not exercised.
2. **upload first**: `stop` runs while synth is `in_progress`, logs "leaving the VM up", skips. Synth finishes; the next watchdog tick deallocates.

Record whichever happens. If (1), the skip branch is still observed cheaply: dispatch `synth.yml` the moment Run B's `upload-checkpoints` job starts (visible via `gh run watch`), so the synth run is queued when B's `stop` guard evaluates — a 1–2 minute window that is easy to hit by polling, and harmless to miss and retry on a later slice run. Either ordering also produces the watchdog's `VM busy, leaving it up` observation on the hourly ticks during the 3 h synth run.

Finding to record either way: ordering (1) delays checkpoint upload by a synth run's length — harmless, but it means the P&R run's wall-clock and its Blob upload time can include a synth run.

### D4: The idle-deallocate observation is the tick after whichever run last leaves the VM up

Ordering (2) in D3 leaves the VM running after synth completes, so the next hourly tick *must* take the `Deallocate idle VM` branch — that is the observation. If every run in this change happened to deallocate via `stop` instead, the fallback is to `az vm start` the VM by hand with nothing queued and wait for the next tick (≤ 1 h, ≤ $1.20). Observation = the watchdog run's log shows the deallocate step executed **and** `az vm get-instance-view` reports `PowerState/deallocated` afterwards; both are read-only checks.

### D5: Backstop sequencing — delete the schedule only after D4, via `az resource delete`, then prove drift is zero

Order is the whole point: ci-pnr-lane D6 (3) forbids a window with no backstop. Once D4 is observed, the schedule is deleted by resource ID (`Microsoft.DevTestLab/schedules/shutdown-computevm-newt-synth-runner`) rather than through `az vm auto-shutdown --off`, so the command names exactly the drift-table row it removes. Post-checks: `az resource list` shows nine resources, all mapping to declared ones; `az vm get-instance-view` shows no auto-shutdown; a template `what-if` is *not* re-run (the schedule was never declared, so the template is unaffected). Rollback if ever needed: `az vm auto-shutdown -g newt-synth-lane-rg -n newt-synth-runner --time 1000` recreates an equivalent disabled-by-default schedule.

The `azure-infrastructure` spec's exception clause is removed in the same change (delta spec), so that spec and reality stop disagreeing the moment the resource is gone.

### D6: Re-enable the synth schedule as the plan says, and record — not fix — what a nightly run does against a deallocated VM

`synth.yml` has no `start` job, so a 02:30 UTC scheduled run against a deallocated VM simply queues. Expected behaviour, to be confirmed by observation over a few nights and recorded in `synth.yml`'s header: the queued job sits until either the VM comes up for some other reason (a P&R run's `start` job, a manual start), at which point it runs and delays that other job by ~3 h — explicitly accepted by the coexistence requirement — or GitHub's 24-hour queue limit for self-hosted jobs fails it, roughly when the next night's run supersedes it under the `synth-refs/heads/main` concurrency group anyway. Net effect: "nightly" degrades to "whenever the VM is up", in practice weekly alongside the P&R cron, at ~$3.60 per ride-along; the Actions history will show a failed or cancelled synth run per idle night.

The watchdog and `stop` guards are unaffected: the watchdog only inspects activity when the VM is running, and a queued synth run that *is* picked up is exactly the case the guards exist for. If observation shows something worse than the above (for example the queued run blocking a P&R `start` from ever assigning the runner), that is a finding for the user, not something this change fixes silently.

*Alternative:* add `start`/`stop` jobs to `synth.yml` — a standing cost decision (~$110/month for genuine nightly synth) already parked in ci-pnr-lane's Open Questions; kept there.

### D7: The weekly P&R cron stays as found — flagged, not changed

The plan's "enable the weekly cron" is already true. Leaving it means ~$30 and ~26 h per week, half of it a `drt` iteration that Phase 11 has shown cannot converge on the current placement. That is a Phase 11 / cost decision for the user (Open Questions); this change neither disables the cron nor adds a `drt` skip to scheduled runs, because either would change the lane's published behaviour under the guise of verification.

### D8: Who does what — paid or destructive steps are the user's; observation is the agent's

Following azure-infra-as-code D9: triggering any run that starts the VM (Run A if dispatched, Run B, the synth dispatch, a manual `az vm start`) and deleting the schedule are user-executed or explicitly user-approved, because each spends money or removes a resource. Read-only verification (`gh run view`, `az vm get-instance-view`, `az resource list`, log inspection), `gh workflow enable` (reversible), and all file edits are the agent's.

### D9: Documentation scope is exactly the files that still describe the pre-watchdog world

- `synth.yml` header note (1): manual lifecycle, 10:00 UTC auto-shutdown, "known gap until Phase 6" → deallocated-by-default VM, started by `pnr.yml` or by hand, watchdog cleans up, schedule behaviour per D6.
- `vm-watchdog.yml` header: "the auto-shutdown is removed once this has been observed" → past tense, with the run ID that observed it.
- `pnr.yml`: document the new inputs; its comments pointing at `openspec/changes/ci-pnr-lane/...` now resolve under `archive/2026-09-13-ci-pnr-lane/` — fix the paths while there.
- `docs/infra-plan.md`: Phase 5 "History" paragraph and Phase 6's "one undeclared resource" paragraph, Phase 9 checkboxes with the observing run IDs, Risks row "Azure cost creep".
- `infra/azure/README.md`: drift table (10 → 9 rows), the exception prose, and the cost-guardrails sentence.
- `docs/pnr-pipeline.md`: the `restore-checkpoints` row and wherever the knobs are described.
- Archived change directories are history and stay untouched.

## Risks / Trade-offs

- **Run A costs ~$30 and most of it is a doomed `drt`** → It is the cadence the plan already committed to; using the Friday scheduled run means no *additional* spend. The user can shrink it by deciding on D7's open question before Friday.
- **Cache-key over-inclusion bit for real** (an `include` line in `Makefile` invalidated a 3 h netlist and a checkpoint set) → Accepted by the key's own design comment; recorded here and in `docs/infra-plan.md` so a future change can narrow the key (hash only the synth-relevant Makefile includes) with the evidence in hand. Not done here.
- **Job-assignment order between a queued synth run and `upload-checkpoints` is not controllable** → Both orderings satisfy the spec; D3 gives a cheap deterministic way to observe the skip branch regardless.
- **Watchdog/`start` race** (ci-pnr-lane D6 residual): a tick could deallocate just as a `start` job is powering the VM → Unchanged; worst case a run's `start` is idempotent and re-issues. Watch for it during the overlap window and record if seen.
- **Perpetually queued nightly synth runs may clutter the Actions history and could interact with `gh run list`'s default 20-run window in the guards** → A queued run is by definition among the most recent, so the guards still see it; clutter is cosmetic. If it turns out to be worse than cosmetic, disable the schedule again and escalate D6's open question.
- **The 24-hour queue limit is remembered behaviour, not verified here** → The task records what actually happens rather than asserting it.
- **A dispatch input with a typo** → The driver rejects unknown stage names with a `::error` before running anything, and a bad `resume_exclude` name simply excludes nothing (the restore step lists what it kept, so it is visible in the log).

## Migration Plan

Order is load-bearing (D5):

1. Merge this change's workflow/doc edits (inputs, headers) — a PR that only touches `.github/`, `docs/`, `infra/azure/README.md`, `openspec/`; the fast lane and `infra.yml` validate it, no VM involved.
2. Run A (Friday cron, or a dispatch). During its `pnr` job: dispatch `synth.yml` (D3). Read the outcome of `stop`, the synth run, and the watchdog ticks.
3. Run B (resume slice, D1). If D3's skip branch was not observed in step 2, dispatch `synth.yml` during B's `upload-checkpoints` window.
4. Confirm the idle-deallocate tick (D4); fall back to a manual start if needed.
5. Delete the schedule (D5); run the drift check; `gh workflow enable synth.yml` (D6).
6. Fill in run IDs and observations in the docs listed in D9 and in this change's tasks; archive.

Rollback: `gh workflow disable synth.yml`; recreate the schedule with `az vm auto-shutdown` (D5); the dispatch inputs are inert when empty and can be reverted independently.

## Open Questions

- **Should the weekly P&R cron keep running the full flow while `drt` is known not to converge?** Options: leave it (current), gate scheduled runs to stop after `grt_repair` until Phase 11 lands a routable placement, or disable the cron and rely on dispatch. A cost decision for the user; it changes nothing in this change's specs or tasks except which of Run A's two sources is used.
- **Should `synth.yml` get its own `start`/`stop` jobs so "nightly" is real?** Carried over from ci-pnr-lane; D6's observations will give the first real data on how the schedule behaves without them.
- **Should the synth cache key stop tracking the whole root `Makefile`?** Worth a small follow-up once the evidence from this change is written down.
