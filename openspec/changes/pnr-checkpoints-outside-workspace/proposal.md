# Proposal — pnr-checkpoints-outside-workspace

## Why

Run A of `post-merge-ci-verification` (run 34783899813, 2026-09-13/15) completed `pnr` with `grt ok` but uploaded **no** checkpoints to Blob: the overlap-test `synth.yml` run (34820756433) took the shared self-hosted runner in the 2.5 h gap between the `pnr` job finishing and `upload-checkpoints` starting, and its `actions/checkout` `git clean -ffdx` wiped `target/ihp13/openroad/save/` out of the shared workspace. `upload-checkpoints` then found nothing and logged the misleading "pnr job may have failed before floorplan" and exited 0 — a ~26 h, ~$32 run lost its only durable output silently. `pnr.yml`'s `concurrency` group and the `stop` coexistence guard only reason about job order and VM power, not about the workspace both lanes share; the *inbound* direction (restoring checkpoints for a resume) already stages into `/home/newt/pnr-restore` outside the workspace precisely to dodge this wipe, but the *outbound* direction never got the same treatment. Today the only protection is an operator disabling `synth.yml` by hand for the length of every full P&R run (the "fix later, unblock now" decision of 2026-09-15), which makes the coexistence requirement the spec promises a fiction in practice.

Flow stages touched: **CI** only (the P&R lane workflow and its docs). RTL, sim, synth flow, backend flow scripts and sw are untouched — `run_pnr.sh`, `openroad.mk` and the stage Tcl keep writing checkpoints to `save/` exactly as before.

## What Changes

- **`pnr.yml` `pnr` job exports its checkpoints out of the workspace before the job ends.** A new always-run step, immediately after "Place and route", moves every checkpoint `.zip` plus `synth-key.txt` from `target/ihp13/openroad/save/` into a per-run host directory (`/home/newt/pnr-export/<run_id>`, bind-mounted into the job container like `/pnr-restore`), so nothing another job can `git clean` still holds the run's only copy once the runner is released. `pnr_status.log` and `reports/` stay in the workspace for the summary and artifact steps that follow in the same job.
- **`upload-checkpoints` reads from the export directory, not the workspace**, removes it after a successful upload (disk budget), and reports accurately: a `pnr` job that succeeded but exported no checkpoint is now a **failed** upload job with an `::error`, not an info line and exit 0. A `pnr` job that never reached the export step (cancelled/timed out) is reported as such.
- **The export directory is bounded** to one run's worth: the export step prunes previous runs' leftovers first, and the pnr job's existing "Clean previous run's local save/reports" step is unchanged.
- **Docs and comments** describe the new mechanism: `docs/pnr-pipeline.md` (job table, dispatch/resume prose, a Notes entry recording the incident), `pnr.yml`'s step/job comments, and `synth.yml`'s checkout gets a one-line pointer that its clean is now harmless to the P&R lane. `docs/infra-plan.md` records the incident in Phase 5's history and closes the follow-up `post-merge-ci-verification` task 2.1 parked for this change.
- **No change** to `synth.yml`'s behaviour (its checkout keeps cleaning), to the runner topology (still one runner, one job at a time), to `run_pnr.sh`/`openroad.mk`, to the restore path, or to Azure resources/Bicep — the export directory is auto-created by Docker on first use exactly like `/home/newt/synth-cache` and `/home/newt/pnr-restore`.

Not breaking: no input, artifact name, Blob layout (`<run_id>/<name>.zip` + `<run_id>/synth-key.txt`) or exit-status semantics of a successful run changes. The one observable difference is intentional — an upload job that would previously have silently uploaded nothing after a successful flow now fails.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `ci-pipeline`: the "P&R lane coexists with the synth lane on the shared runner" requirement gains the workspace dimension — sharing the runner SHALL NOT let one lane's job destroy the other lane's outputs that are still waiting on a later job — and the "P&R lane publishes routing outputs and preserves checkpoints" requirement gains two scenarios: checkpoints reach Blob even when another lane's job runs on the runner between the P&R job and the upload job, and a successful P&R job with no checkpoints to upload is a visible failure rather than a silent no-op.

## Impact

- `.github/workflows/pnr.yml` — `pnr` job: one new `volumes:` entry, one new `env` var, one new step; `upload-checkpoints` job: rewritten "Upload checkpoints" step body and header comment; workflow-level `env` gains `PNR_EXPORT_HOST_DIR`. No change to any job's `if:`/`needs:`/`runs-on:`/`permissions:`, to the `start`/`restore-checkpoints`/`stop` jobs, or to the dispatch inputs.
- `.github/workflows/synth.yml` — comment only.
- `docs/pnr-pipeline.md`, `docs/infra-plan.md` — documentation.
- `openspec/specs/ci-pipeline/spec.md` — via the delta spec at archive time.
- Runner VM — a new auto-created host directory `/home/newt/pnr-export` on the OS disk, holding at most one run's checkpoints (≈20 GB, the same volume the workspace's `save/` held between runs before) until the next upload or export prunes it. No provisioning, Bicep or `provision-runner.sh` change.
- Sequencing with `post-merge-ci-verification`: the in-flight checkpoint-source run 34938462965 runs the workflow at its own SHA and is unaffected; merging this change before that change's Run B lets Run B's ~15 min slice verify the export→upload path for free, and re-enabling `synth.yml` (its task 5.3) no longer needs to wait for the P&R lane to be idle.
