# Design — pnr-checkpoints-outside-workspace

## Context

See proposal.md — Why. The facts that shape the approach:

- One self-hosted runner (`self-hosted-synth`) serves both `pnr.yml` and `synth.yml`, one job at a time, and every job of every workflow checks out into the same `_work/newt/newt` workspace. `actions/checkout@v4`'s default `clean: true` runs `git clean -ffdx`, which deletes ignored files too — `target/ihp13/openroad/save/` is ignored.
- A workflow's jobs are not scheduled as a unit. Between `pnr` releasing the runner and `upload-checkpoints` acquiring it, any queued job from any workflow can be assigned first. `pnr.yml`'s `concurrency: group: pnr` serializes `pnr.yml` runs against each other only, and the `stop` guard only decides whether to power the VM off.
- Within a job the workspace is safe: the runner is busy, so nothing else can touch it. The only exposure windows are the inter-job gaps, and the only run-critical files that cross a gap in the workspace are the checkpoints and `synth-key.txt` (reports, the DEF and the status log are uploaded as artifacts inside the `pnr` job).
- The inbound direction already solves the identical problem: `restore-checkpoints` stages Blob downloads into `/home/newt/pnr-restore/<run_id>` on the host, bind-mounted into the `pnr` container as `/pnr-restore`, "because the pnr job's own actions/checkout would `git clean -ffdx` the workspace immediately afterwards". The same host-directory-plus-bind-mount pattern serves the synth cache. Docker creates these host directories on first use, owned by root; no provisioning step declares them.
- The `pnr` job runs as root inside `newt-eda:dev`; `upload-checkpoints` runs as the runner user `newt` on the host with no container (az CLI lives on the host, and design D8 of `ci-pnr-lane` gives the `pnr` job no Azure access). Anything the export writes must be readable — and, if it is to be cleaned up after upload, deletable — by `newt`.
- A full run's checkpoints are ≈20 GB (`~1.5 GB × ~13`, infra-plan Appendix A); the OS disk has ~111 GB free and already carries the synth cache, Docker images and the workspace. Until now the previous run's `save/` sat in the workspace between runs anyway (cleared by the next `pnr` job's "Clean previous run's local save/reports" step or by any checkout).
- `post-merge-ci-verification` is mid-flight: run 34938462965 (the replacement checkpoint source) is in its `pnr` job with `synth.yml` `disabled_manually`; its Run B slice (task 3.1) has not been dispatched yet.

## Goals / Non-Goals

**Goals:**

- Make the coexistence requirement true for the workspace, not just for VM power: a P&R run's checkpoints reach Blob no matter which job runs on the runner between `pnr` and `upload-checkpoints`.
- Turn the failure mode from silent (info line, exit 0) into loud (job failure) so it can never again be discovered days later at a resume attempt.
- Keep the flow's own conventions untouched — `save/` under `target/ihp13/openroad`, `run_pnr.sh`'s resume-by-presence, manual bring-up invocations, `docs/pnr-pipeline.md`'s stage table.
- Keep the mechanism symmetrical with the restore path so there is one pattern to understand.

**Non-Goals:**

- Protecting manual out-of-band work on the VM workspace (`docker exec` driving the flow by hand). That sharp edge stays documented as-is; the fix is to go through `pnr.yml`.
- Changing runner topology (a second runner, separate `_work` roots), the `stop` guard, `vm-watchdog.yml`, or the synth lane's lifecycle.
- Re-enabling `synth.yml` or dispatching any run — those remain `post-merge-ci-verification`'s tasks 5.3 / 3.1 / 3.3 and follow that change's D8 (paid actions are the user's).
- Any Bicep, `provision-runner.sh` or Azure resource change.

## Decisions

### D1: Export checkpoints to a per-run host directory outside the workspace at the end of the `pnr` job; `upload-checkpoints` reads from there

The `pnr` job gets a third bind mount, `/home/newt/pnr-export:/pnr-export` (workflow env `PNR_EXPORT_HOST_DIR=/home/newt/pnr-export`, container env `PNR_EXPORT_DIR=/pnr-export`, mirroring `PNR_RESTORE_HOST_DIR`/`PNR_RESTORE_DIR`), and a new step "Export checkpoints out of the shared workspace" that moves `target/ihp13/openroad/save/*.zip` and `save/synth-key.txt` into `/pnr-export/${GITHUB_RUN_ID}`. `upload-checkpoints` uploads from `${PNR_EXPORT_HOST_DIR}/${GITHUB_RUN_ID}` with the same `upload-batch` + marker-upload commands as today, then removes the directory.

Why this over the alternatives:

- *Upload from inside the `pnr` job* — needs the az CLI in the EDA image and Azure credentials in the container job, both deliberately excluded by `ci-pnr-lane` D8. Rejected.
- *Point `SAVE` at the host directory for the whole flow* (`make ... SAVE=/pnr-export/...`) — zero copy, but it changes the cwd-relative convention every stage script, `run_pnr.sh`'s dry run, the summary/artifact steps, the restore step and the docs all assume, and diverges CI from manual invocations. The copy costs minutes on a multi-hour job; the divergence costs every future reader. Rejected.
- *Cross-workflow concurrency group* (give `synth.yml`'s job `group: pnr`) — a synth run waiting on a concurrency group is `pending`, which neither the `stop` guard nor the watchdog counts as "queued on the runner", so `stop` would deallocate the VM and the synth job would then queue against a powered-off VM until GitHub's 24 h limit fails it. That contradicts the "synth job queues and runs after the P&R job, and the stop step leaves the VM up for it" scenario. Rejected.
- *`clean: false` on `synth.yml`'s checkout* — leaves synth building on a stale tree, protects only against `synth.yml` (any future workflow on this runner reintroduces the bug), and still leaves 20 GB of someone else's files in the workspace. Rejected.
- *Second runner registration on the same VM with its own `_work`* — real isolation, but two runners mean two concurrent jobs on one 16-vCPU/128 GB VM (synth peaks at ~35 GB, `drt` at ~30 GB, both CPU-hungry), and every guard (`stop`, watchdog, `concurrency`) assumes one job at a time. A much bigger change for the same outcome. Rejected.

### D2: The export step runs right after "Place and route", always, and moves only the files that cross the gap

- `if: always()`: a failed or stopped flow's partial checkpoints are exactly what the "Failed run still publishes diagnostics" scenario needs uploaded.
- Placed immediately after the P&R step rather than last, so the checkpoints are safe before the summary and artifact-upload steps run (those cannot destroy anything, but a runner outage during them would otherwise leave the checkpoints exposed).
- Moves `*.zip` and `synth-key.txt` only. `pnr_status.log` stays because the "Stage-status summary" and "Upload reports and logs" steps read it from `save/` afterwards; `reports/` stays because it is uploaded as an artifact in the same job. Nothing else in `save/` is needed later.
- `mv` across the bind-mount boundary degrades to copy-then-unlink per file (rename(2) fails with EXDEV across mounts even on one filesystem), so peak extra disk is one checkpoint, and the workspace copy is gone by the time the step ends. Expected cost ≈ 20 GB at OS-disk speed: minutes, logged with `du -sh` before and elapsed time after.
- The step lists what it exported (name and size, like the restore job does) so the log answers "were there checkpoints at the end of `pnr`?" independently of what the upload job later finds.
- Before writing, the step removes everything else under `/pnr-export` (it runs as root, so ownership never blocks the prune): the directory is bounded to one run's checkpoints — the same volume the workspace's `save/` held between runs before this change, so the OS-disk budget does not move.

### D3: Ownership is handled by the exporter, cleanup by the uploader, pruning by the next exporter

Docker creates `/home/newt/pnr-export` root-owned; the container writes as root; the uploader runs as `newt`. The export step therefore ends with `chmod a+rwx /pnr-export` and `chmod -R a+rwX /pnr-export/${GITHUB_RUN_ID}`, so `newt` can read every file and remove the directory. After a successful `upload-batch` and marker upload, `upload-checkpoints` runs `rm -rf` on the run's directory — Blob is the durable copy and the ~30-day lifecycle rule governs it. If the upload fails, the directory stays for diagnosis and the next run's export step prunes it (D2). No provisioning change: this is the same auto-created-by-Docker pattern the synth cache and restore directory already rely on.

*Alternative:* pre-create the directory as `newt` in `provision-runner.sh`. Cleaner ownership but a VM-side change that has to be converged by hand on the live host and would leave the workflow broken on any runner where it was not run; the chmod is self-contained. Rejected for now (see Open Questions).

### D4: `upload-checkpoints` reports each of its four outcomes precisely, and fails when a successful flow left it nothing

With `needs: pnr` and `if: always()`, the job can read `needs.pnr.result`. Source directory `${PNR_EXPORT_HOST_DIR}/${GITHUB_RUN_ID}`:

1. **Directory missing** → the `pnr` job never reached the export step (cancelled, timed out, or the runner lost the job). `::warning` naming the path and the `pnr` result; exit 0 — the `pnr` job's own status is the verdict, and there is nothing to preserve.
2. **Directory present, no `.zip`, `needs.pnr.result != 'success'`** → the flow failed before its first checkpoint. Info line saying so; the marker alone is not uploaded (nothing to resume onto); exit 0.
3. **Directory present, no `.zip`, `needs.pnr.result == 'success'`** → exactly Run A's failure class. `::error` naming the directory and exit 1, so the run's outcome shows a red `upload-checkpoints` job. (`stop` has `if: always()` and is unaffected, so the VM still gets deallocated.)
4. **Zips present** → `upload-batch`, then the `synth-key.txt` marker if present, then `rm -rf` the directory. Log the count and total size.

The old "pnr job may have failed before floorplan" text goes away; every branch states what it actually knows.

### D5: Validation is cheap and local; real-run proof rides on the run `post-merge-ci-verification` already needs

- Completion gate for the workflow edit: `actionlint`; `git diff` shows no change to any job's `if:`/`needs:`/`runs-on:`/`permissions:`; and a local rehearsal of the two step bodies — extracted verbatim from `pnr.yml` into the scratchpad, run against a scratch tree with a fake `GITHUB_WORKSPACE`, a fake export root, and a stub `az` on `PATH` — covering D2's move/prune/chmod and all four D4 branches. This mirrors how the dispatch-input change was validated with `PNR_DRY_RUN=1`.
- Real-run verification: `post-merge-ci-verification` task 3.1 (Run B, ≈15 min) exercises export → upload end-to-end once this change is on `main`; its verify text already requires a fresh `synth-key.txt` in Blob. The collision itself is reproduced, if the user wants the direct evidence, by combining with that change's task 3.3: dispatch `synth.yml` while a slice run's `pnr` job is in progress and let GitHub pick the order — ordering (1) (synth first) proves this fix under the real wipe, ordering (2) is the skip-branch observation 3.3 wants. Either outcome is useful, so the test is never wasted. Paid actions stay the user's (that change's D8).
- Documentation: `docs/pnr-pipeline.md`'s job table, the `concurrency` paragraph that today says the workspace is only a manual-work hazard, and a Notes entry recording the 2026-09-15 incident with its run IDs; `pnr.yml`'s `upload-checkpoints` header (which currently *justifies* reading the workspace: "the self-hosted runner's own workspace is host-visible regardless of which job/container wrote to it"); a one-line comment on `synth.yml`'s checkout; `docs/infra-plan.md` Phase 5 history and the follow-up that `post-merge-ci-verification` task 2.1 parked for this change.

## Risks / Trade-offs

- **The move adds minutes to the `pnr` job and 20 GB of write I/O at its end** → Negligible against a 15 min–26 h job; logged so it can be measured. If it ever matters, D1's rejected `SAVE=` override is the zero-copy path.
- **Export directory left behind after a failed upload** → Bounded to one run by the next export's prune; the OS-disk budget is unchanged versus the pre-change behaviour of leaving `save/` in the workspace.
- **`chmod` on a bind-mounted root-owned directory from inside the container** → Standard Docker behaviour (the mount is the host directory); the local rehearsal cannot test the cross-user part, so Run B's `upload-checkpoints` log is the first real check. If the `rm -rf` fails, the job only warns — the upload has already succeeded — and the next export prunes as root.
- **A run's `upload-checkpoints` is now red when a successful flow saved nothing** → Intended. The only known way to reach it is the collision this change removes; if it fires for another reason, it is a new finding, not noise.
- **Manual out-of-band work on the VM still collides with CI checkouts** → Out of scope, still documented; nothing here makes it worse.
- **`restore-checkpoints` and `upload-checkpoints` directories are two root-owned host paths with no declaration anywhere** → Same status as `/home/newt/synth-cache` today; recorded as an Open Question rather than fixed here.

## Migration Plan

1. Open a PR touching only `.github/workflows/pnr.yml` (plus the `synth.yml` comment), `docs/`, and `openspec/`; the fast lane validates it, no VM involved. Merge once `lint`/`sw` are green.
2. The in-flight run 34938462965 runs the workflow at its own SHA and is unaffected. Do not re-enable `synth.yml` for this change; that decision stays with `post-merge-ci-verification` 5.3 — but once this change is merged that re-enable no longer has to wait for the P&R lane to be idle.
3. Dispatch Run B (that change's 3.1) after the merge so it verifies the new upload path. Its `restore-checkpoints` still reads `/home/newt/pnr-restore` — the restore side is unchanged.
4. Rollback: revert the PR. The upload job goes back to reading the workspace; nothing in Blob, Azure or the VM needs undoing (an orphaned `/home/newt/pnr-export` is ≤ 20 GB and harmless).

## Open Questions

- Should the three host-side directories the lanes depend on (`synth-cache`, `pnr-restore`, `pnr-export`) be declared and created by `provision-runner.sh`, owned by `newt`, so ownership is not a per-workflow `chmod` concern? A small follow-up to `infra/azure`, not needed for this change to work.
- If the OS disk gets tight, should the export and restore directories move to a dedicated data disk? Only if a future run reports disk pressure; the budget is unchanged today.
