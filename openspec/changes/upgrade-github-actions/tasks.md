# Tasks — upgrade-github-actions

Cost legend used below: **[edit]** = plain file editing, no tools, seconds.
**[hosted-CI]** = verified by a GitHub-hosted lane, minutes, free-ish.
**[long-run]** = needs the self-hosted EDA runner (synth ~2.5 h, P&R >24 h) —
never a blocking gate for this change; see design.md Decision 4.

## 1. Resolve pins

- [x] 1.1 **[edit]** Re-resolve the current latest release tag and its full 40-char commit SHA for each third-party action — `docker/build-push-action`, `docker/setup-buildx-action`, `docker/login-action`, `azure/login` — via `gh api repos/<owner>/<repo>/releases/latest --jq .tag_name` then `gh api repos/<owner>/<repo>/commits/<tag> --jq .sha`. Do NOT copy design.md's table; a newer patch may have shipped. Verify: four tag/SHA pairs recorded, each SHA exactly 40 hex characters.
- [x] 1.2 **[edit]** Re-confirm the current latest major for `actions/checkout` and `actions/upload-artifact` (expected v7 for both). Verify: both tags resolve via `gh api`.

## 2. Bump first-party actions

- [x] 2.1 **[edit]** Update all 9 `actions/checkout@v4` references to the resolved major in `ci.yml` (lines ~44, 193, 222, 241, 284), `docker-image.yml` (~26), `infra.yml` (~37), `pnr.yml` (~237), `synth.yml` (~97), preserving each site's existing `with:` block (`fetch-depth: 0` on three of them) and all surrounding comments. Verify: `grep -rc 'actions/checkout@v4' .github/workflows/` returns 0 matches and `grep -rc 'actions/checkout@v7' .github/workflows/` totals 9.
- [x] 2.2 **[edit]** Update all 4 `actions/upload-artifact@v4` references in `pnr.yml` (~663, 672) and `synth.yml` (~196, 205), leaving `name`/`path`/`retention-days`/`if-no-files-found` untouched. Verify: no `upload-artifact@v4` remains; 4 sites on the new major.

## 3. Bump and SHA-pin third-party actions

- [x] 3.1 **[edit]** Replace all 5 `azure/login@v2` references (`pnr.yml` ~118, 173, 704, 785; `vm-watchdog.yml` ~47) with `azure/login@<sha> # v3.x.y` using the pair from 1.1. Verify: `grep -n 'azure/login@' .github/workflows/` shows 5 lines, each a 40-char SHA with a version comment.
- [x] 3.2 **[edit]** Replace all 6 `docker/build-push-action@v6` references in `docker-image.yml` (~56, 65, 74, 83, 92, 101) with the pinned v7 SHA + version comment, leaving every `with:` block unchanged. Verify: 6 pinned lines, no `@v6` remains.
- [x] 3.3 **[edit]** Replace `docker/setup-buildx-action@v3` (~29) and `docker/login-action@v3` (~41) in `docker-image.yml` with their pinned v4 SHAs + version comments. Verify: both lines pinned; the `login-action` `with:` block (registry/username/password) is byte-identical to before.
- [x] 3.4 **[edit]** Confirm no v7-removed input or env is in use: `grep -rn 'DOCKER_BUILD_NO_SUMMARY\|DOCKER_BUILD_EXPORT_RETENTION_DAYS' .github/` returns nothing, and the `setup-buildx-action` call site passes no inputs. Verify: both greps empty (expected — this re-checks the proposal's finding against the edited files).

## 4. Completeness check

- [x] 4.1 **[edit]** Run a whole-tree audit rather than reading the diff: `grep -rhoE 'uses:\s*\S+' .github/ | sed 's/uses:\s*//' | sort | uniq -c`. Verify: exactly 6 distinct actions, counts 9/4/5/6/1/1, every `docker/*` and `azure/*` entry a 40-char SHA, every `actions/*` entry the intended major, and zero references to any old version.
- [x] 4.2 **[edit]** Verify every workflow file still parses as YAML (e.g. `python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.yml')]"`). Verify: exits 0.

## 5. Dependabot

- [x] 5.1 **[edit]** Create `.github/dependabot.yml` with `version: 2` and a single `package-ecosystem: github-actions` entry: `directory: "/"`, `schedule.interval: weekly`, and a `groups:` block collecting all action updates into one PR (design.md Decision 3). Add no other ecosystem. Include the project's SPDX header per `project.md` conventions. Verify: file parses as YAML and declares exactly one ecosystem entry.
- [x] 5.2 **[edit]** Confirm no auto-merge is configured for these PRs — `.github/dependabot.yml` contains no auto-merge directive and no auto-merge workflow is added. Verify: `grep -rn 'auto-merge\|automerge' .github/` returns nothing.
- [ ] 5.3 **[hosted-CI]** After merge, confirm Dependabot is live: the repository's Insights → Dependency graph → Dependabot tab lists the `github-actions` ecosystem without a config error. Verify: ecosystem listed, last-checked timestamp populated, no parse error banner.

## 6. Gate: hosted lanes

- [ ] 6.1 **[hosted-CI]** Open the PR and confirm `ci.yml`'s container jobs pass. Pay specific attention to the git-dependent steps that sit on the `checkout` v6 credential-persistence seam (design.md Risks): the `lint` job's `bender sources` step and the `sw` job's `make ig-sw-all`. Verify: both jobs green, and neither log shows a git auth, `safe.directory`, or dubious-ownership error.
- [ ] 6.2 **[hosted-CI]** Confirm `docker-image.yml` passes — this is the only lane exercising all three pinned `docker/*` actions. Verify: every build stage completes and pushes its `:ci` working tag to GHCR as before; the composite `FROM <local-tag>` resolution still works.
- [ ] 6.3 **[hosted-CI]** Confirm `infra.yml` passes (Bicep validation, exercises `checkout` on a non-container hosted job). Verify: job green.
- [ ] 6.4 **[hosted-CI]** Confirm no required status check changed name or disappeared, so branch protection still matches. Verify: the PR's check list has the same job names as the previous run on `main`.

## 7. Post-merge verification on the expensive lanes

- [ ] 7.1 **[long-run]** On the next `synth.yml` run (scheduled or dispatched), confirm the lane starts cleanly under the new action versions. Verify: `checkout` and both `upload-artifact` steps complete, no "unsupported runtime"/"runner version" error appears in the first minute of the job, and the netlist/reports artifacts upload as before. A runtime failure here surfaces within seconds of job start — do not wait out the ~2.5 h flow to detect it.
- [ ] 7.2 **[long-run]** On the next `pnr.yml` run, confirm the same for its `checkout`, two `upload-artifact`, and four `azure/login` steps — the `azure/login` sites gate VM start/deallocate and checkpoint upload, so a failure there risks a VM cost leak (see the existing deallocation requirement). Verify: start and stop jobs both succeed, checkpoints upload, VM ends deallocated.
- [ ] 7.3 **[long-run]** Record the self-hosted runner's Actions Runner version from the first self-hosted job log of 7.1 or 7.2 (the runner prints it in the job's setup section) into this change's notes. Verify: version captured and confirmed ≥ 2.327.1. If it is below that floor, treat it as a blocking finding: update the runner (or revert `synth.yml`/`pnr.yml` per design.md's narrow rollback) before relying on these lanes.
- [ ] 7.4 **[hosted-CI]** Confirm `vm-watchdog.yml` works on its next scheduled tick — it is schedule-only, so it gets no PR-time signal and its single `azure/login` is otherwise unverified. Verify: the scheduled run succeeds and authenticates to Azure.

## 8. Wrap-up

- [x] 8.1 **[edit]** Note in `docs/infra-plan.md` that action references are now SHA-pinned for third-party actions and watched by Dependabot, so future contributors do not re-introduce tag-only references. Verify: the note exists and names the pinning convention (SHA + `# vX.Y.Z` comment).
- [ ] 8.2 **[edit]** Sync the `ci-pipeline` delta into the main spec and archive the change once 7.1–7.3 have reported. Verify: `openspec validate --changes` passes and the three new requirements appear in `openspec/specs/ci-pipeline/spec.md`.
