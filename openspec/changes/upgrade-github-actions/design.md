## Context

See `proposal.md` — Why. This section records only the facts that shape the approach.

Six distinct actions appear across 22 `uses:` sites in six workflow files. The upgrades are not six independent migrations: `actions/checkout` v5, `actions/upload-artifact` v6, `azure/login` v3, `docker/build-push-action` v7, `docker/setup-buildx-action` v4, and `docker/login-action` v4 are all, at bottom, the same change — `runs.using: node24`, floor of Actions Runner 2.327.1. The majors above those floors (checkout v6/v7, upload-artifact v7) add ESM packaging, a credential-persistence change, a fork-PR guard, and an opt-in unzipped upload; none alters the inputs these workflows pass.

Three constraints shape how this can be validated:

1. **The gating lanes are cheap; the lanes that matter most are not.** `ci.yml`, `docker-image.yml`, `infra.yml`, and `vm-watchdog.yml` run on GitHub-hosted runners and give real signal within minutes. `synth.yml` is ~2.5 h and `pnr.yml` is >24 h on a single self-hosted VM, and per `project.md` full-flow validation cannot be a per-change gate.
2. **The self-hosted runner is unobservable right now.** `newt-synth-runner` is offline — deallocated between runs by design (`pnr.yml`'s start/stop jobs). Its Actions Runner version cannot be read without starting the VM.
3. **Three lanes execute inside a container.** `ci.yml`, `synth.yml`, and `pnr.yml`'s `pnr` job run in `ghcr.io/wortexx/newt-eda:dev`. The runner injects its own Node binary into that container, so the action runtime is constrained by the *image's* glibc, not the host's. The image is `ubuntu:24.04` (glibc 2.39) — well clear of node24's floor.

## Goals / Non-Goals

**Goals:**

- Land all six bumps as one reviewable, behaviour-neutral change rather than six trickling PRs.
- Make the resulting `uses:` lines self-documenting: a reader sees both what is pinned and which version it is.
- Ensure the next drift of this kind is surfaced by machinery, not by someone noticing.
- Leave a clear, cheap rollback for the expensive lanes, which cannot be validated pre-merge.

**Non-Goals:**

- Re-architecting workflows, consolidating duplicated steps, or extracting composite actions. Twenty-two call sites is an invitation to refactor; taking it would destroy this change's reviewability as a pure dependency bump.
- Validating the synth or P&R lane before merge. See Decision 4.
- Adopting Dependabot for any ecosystem other than `github-actions`.

## Decisions

### Decision 1: Go straight to the latest major, not to the Node 24 floor

Each action moves to its current latest release in one step — `checkout` v4 → v7, not v4 → v5.

*Why:* The intermediate majors are inert for this repository. Every deprecation they carry was checked against the actual call sites and none applies: `build-push-action` v7 drops `DOCKER_BUILD_NO_SUMMARY` and `DOCKER_BUILD_EXPORT_RETENTION_DAYS` (absent from `.github/` entirely); `setup-buildx-action` v4 drops deprecated inputs (its one call site passes none); `upload-artifact` v7's ESM rewrite and opt-in `archive: false` change nothing for callers passing only `name`/`path`/`retention-days`/`if-no-files-found`; `checkout` v7 blocks fork-PR checkout under `pull_request_target` and `workflow_run`, neither of which this repository uses. Stopping at v5 would mean paying the same validation cost twice within months.

*Alternative rejected:* Step through each major with a validation run between. Defensible if the intermediate majors carried real risk here — they demonstrably do not, and each step's validation would have to wait on the expensive lanes.

### Decision 2: SHA-pin third-party actions, tag-pin first-party

`docker/*` and `azure/login` get a 40-character commit SHA plus a `# vX.Y.Z` trailing comment. `actions/*` stays on major tags.

*Why:* A mutable tag can be repointed without any change here. What runs on these runners is not low-value: the self-hosted lane holds Azure OIDC federation to a subscription that can start and stop VMs, and `docker-image.yml` holds GHCR write. The comment matters as much as the SHA — an unannotated hash makes review impossible and would cause the pins to rot faster than tags. Keeping `actions/*` on tags is a deliberate trust boundary: GitHub controls both that namespace and the runner executing it, so a SHA pin there buys much less while costing the same legibility.

*Alternative rejected:* Pin everything to SHAs. Marginally stricter, but it doubles the annotation burden for no change in the threat model, and makes the `actions/*` lines — the ones a reader scans most — the least readable in the file.

*Alternative rejected:* Pin nothing. This is what produced the current state.

The SHAs at time of writing:

| Action | Version | SHA |
|---|---|---|
| `docker/build-push-action` | v7.4.0 | `c3c9e263c25d99ce0380d002d59b67737d91b0dc` |
| `docker/setup-buildx-action` | v4.4.1 | `f87e5991a6d7451dcb8d9637bfbc97413f497069` |
| `docker/login-action` | v4.6.0 | `dbcb813823bdd20940b903addbd779551569679f` |
| `azure/login` | v3.1.0 | `a641126d1b8aa4d1fa005f4f92df94a3a4c4c906` |

These MUST be re-resolved at implementation time rather than copied from this table — a newer patch release may have shipped since, and a stale table is exactly the failure mode SHA pinning is meant to prevent.

### Decision 3: Dependabot, weekly, grouped, no auto-merge

One `.github/dependabot.yml` with a single `github-actions` ecosystem entry, weekly interval, updates grouped into one pull request.

*Why weekly, not daily:* Six actions across four organizations is a low release rate. Daily buys nothing and trains the reader to ignore the PRs.

*Why grouped:* Ungrouped, a busy week produces five PRs, each firing the full hosted lane. Grouped, it produces one — and one is what actually gets reviewed.

*Why no auto-merge:* The gating lane does not exercise the synth or P&R lanes, so a green check on a Dependabot PR is not evidence that the expensive lanes still work. Auto-merging on that signal would reintroduce exactly the uncontrolled-runtime-swap risk this change exists to remove.

Dependabot understands SHA-pinned references with version comments and updates both together, so Decision 2 and Decision 3 compose rather than conflict.

### Decision 4: Validate on the hosted lanes pre-merge; carry the self-hosted lanes as post-merge verification

The merge gate is the hosted lanes. The synth and P&R lanes are verified on their next scheduled or dispatched run, after merge.

*Why:* `project.md` states outright that full-flow validation cannot be a per-change gate — 2.5 h and >24 h on one contended VM. The evidence that the self-hosted runner will cope is strong but indirect: `infra/azure/provision-runner.sh` installs the latest `actions/runner` release, and repository-scoped runners self-update by default, so it should already be well past the 2.327.1 floor. It is not proof, because the VM is off.

This is the change's one genuine unknown, and it is deliberately carried rather than resolved, per the choice recorded at proposal time. The mitigation is that the failure is loud, immediate, and trivially reversible: an unsupported action runtime fails at step startup, within seconds of the job beginning, not hours into the flow.

*Alternative rejected:* Start the VM to read the runner version before merging. Correct in a vacuum; it costs a VM start and a manual step to confirm something that the fast, cheap failure mode already makes safe.

*Alternative rejected:* Split into hosted-now / self-hosted-later changes. Leaves the repository in a mixed state where two lanes reference v4 and four reference v7, which is harder to reason about than the risk it removes.

## Risks / Trade-offs

**Self-hosted runner is below 2.327.1 → the synth and P&R lanes fail at step startup.** The single real risk. Mitigated by the failure being immediate and unambiguous (an explicit unsupported-runtime error, seconds in, not a silent misbehaviour) and by the rollback below being a one-line revert. The verification task makes this an owned check with a named trigger rather than something noticed when a weekly run is already red.

**`checkout` v6 moves persisted credentials from git config into a separate file → container jobs could lose repository auth.** All three container lanes check out as the runner user and then run `git config --global --add safe.directory '*'` because the container's user does not own the tree. The credential file is written under `.git/` with the same ownership the tree already has, and these lanes only use git to read the checked-out tree and to let Bender clone *public* dependencies — no authenticated fetch. Expected to be inert, but it is the one v6 change that touches a workflow-visible seam, so the container lanes' git-dependent steps (`bender sources`, `make ig-hw-all`) are called out explicitly in the validation tasks rather than assumed.

**Twenty-two mechanical edits → a missed or mistyped call site.** A single wrong SHA character fails the run outright, which is safe; the worse case is a call site left on v4 and not noticed. Mitigated by a grep-based completeness check over `.github/` as an explicit task, not by reading the diff.

**Grouped Dependabot PRs are harder to bisect than individual ones.** Accepted: when a grouped PR is red, splitting it is a manual but rare operation, and the alternative is PR noise that gets ignored — the failure mode that produced this change.

**SHA pins make the workflow files less readable.** Accepted and partly mitigated by the mandatory version comment. This is the cost of Decision 2 and is paid deliberately.

## Migration Plan

1. Re-resolve each third-party action's SHA from its current latest release; do not trust this document's table.
2. Apply all 22 edits plus `.github/dependabot.yml` in one commit.
3. Open the PR. The hosted lanes (`ci.yml`, `docker-image.yml`, `infra.yml`) run as the gate; `vm-watchdog.yml` is schedule-only and is verified on its next tick.
4. Merge on green.
5. On the next synth or P&R run, confirm the lane's steps start and reach their normal outcome, and record the runner version observed in the job log.

**Rollback:** revert the single commit. Nothing outside `.github/` changes, no state migrates, and no artifact, cache, or credential outlives the revert — the previous action versions resume on the next run with no cleanup. If only the self-hosted lanes prove to be the problem, the narrower rollback is to restore v4 references in `synth.yml` and `pnr.yml` alone while leaving the hosted lanes upgraded.

## Open Questions

None. The self-hosted runner's version is unknown but is not an open question in the deferrable sense — it is a known unknown with an owned verification task, a predicted outcome, and a rollback if the prediction is wrong.
