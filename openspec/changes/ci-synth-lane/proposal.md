## Why

Nothing today exercises the full pickle → yosys synthesis flow automatically: a regression anywhere in `ig-hw-all`/`pickle-all`/`synth-all` (an RTL change that breaks elaboration, a Bender pin drift, a tool behavior change) only surfaces when someone volunteers a ~3 h run on a >32 GB machine. Phase 3's fast lane deliberately excludes this — full-chip synth is far too expensive to gate every PR — and `docs/infra-plan.md` Phase 4 slots it as its own scheduled/on-demand lane. The prerequisites are now in place: Phase 1 shipped a `newt-eda` image whose adoption gate ran this exact flow end-to-end (PASS, ~2 h 28 m, peak 29.6 GB) and produced the reference numbers (cell count, area, DFF count) a CI summary can compare against.

**Flow stages touched:** CI only. The synth flow itself (pickle + yosys makefiles, scripts) is invoked as-is; this change adds automation and reporting around it, not changes to it. No RTL / sim / backend / sw changes.

## What Changes

- Add `.github/workflows/synth.yml` — a separate workflow from the fast lane's `ci.yml`, with its own triggers: nightly cron on `main`, `workflow_dispatch`, and pull requests carrying the `full-synth` label from a same-repo branch (re-running on subsequent pushes while the label is present).
- The single `synth` job runs `make ig-hw-all && make pickle-all && make synth-all` in the `newt-eda` container. **Superseded during implementation:** the plan's original choice of a GitHub-hosted large runner turned out to be unavailable — that feature requires a Team/Enterprise organization plan, and `wortexx/newt` is a personal-account repo. Verified via `gh api` before anything was built on the assumption (see design.md D1). The user chose to pull the minimum slice of Phase 5/6's self-hosted Azure VM forward instead: one manually provisioned VM (no Terraform/OIDC/golden-image yet), registered as a GitHub Actions self-hosted runner. This is a real scope change from the original plan, not a substitution made silently — see design.md D1/D1a/D1b for the full account, including the public-repo security posture a self-hosted runner requires.
- Upload the synthesized netlist and the yosys report directory as workflow artifacts.
- Post a run summary (GitHub step summary): cell count, chip area, DFF count, and WNS, each with its delta vs a **checked-in baseline file** seeded from the Phase 1 adoption-gate numbers.
- Failure semantics: the job fails when the flow fails or when yosys `CHECK` reports problems; metric drift vs baseline is *reported, not gated* (the plan's Phase 4 asks for a posted summary — hard budgets stay with Phase 3's `synth-coproc` idea). The lane is **not** a required status check on `main`.
- Bake in the Appendix B gotchas that apply to this lane: monolithic `synth-all` (never `run-yosys-hier`), explicit `pickle-all` before `synth-all` (`synth-all` does not trigger a pickle rebuild), `sources.json` regenerated in-container (automatic on a fresh CI checkout).

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `ci-pipeline`: gains requirements for a scheduled/on-demand full-synthesis lane — when it runs (nightly / manual / labeled PR), what it must produce (netlist + report artifacts, baseline-compared metric summary), and what makes it fail (flow failure or yosys `CHECK` problems — not metric drift, and never as a required merge gate). The capability's purpose broadens from "every push and PR" to also cover this scheduled lane.

## Impact

- **CI:** new `.github/workflows/synth.yml`. Existing `ci.yml` and `docker-image.yml` untouched.
- **Repo files:** a checked-in baseline metrics file plus a small script that extracts cell count / area / DFF count / WNS from the yosys and STA reports and renders the summary (location and format in design.md).
- **Build system:** no makefile changes expected; timing extraction reuses the existing `run-sta` target, overriding its `STA` variable if the image lacks a standalone `sta` binary (verified during implementation — design.md D4).
- **Infrastructure (new — not in the original plan):** one manually provisioned Azure VM (Standard_E16ds_v5 class), Docker installed, registered as a GitHub Actions self-hosted runner (label `self-hosted-synth`) against `wortexx/newt`. This is Phase 5/6 work pulled forward in miniature; Terraform/OIDC/golden-image automation stays deferred to Phase 6 proper. **Blocked pending an Azure subscription appropriate for a personal project** — the only one available on the dev machine at implementation time was the user's employer tenant, not used for this (design.md D1).
- **Repository settings:** the self-hosted runner must be registered before `runs-on` resolves; "Require approval for all outside collaborators" (Settings → Actions → General) must be enabled before the label-triggered PR path is safe to leave on (design.md D1b). Not added to required status checks.
- **Cost:** Azure VM cost is now continuous/direct rather than metered GitHub Actions minutes — roughly $500–700/mo if left always-on at this VM class; mitigated by manual stop/start discipline until Phase 6's deallocate automation lands (design.md D1a). A deliberate cost check-in gates enabling the nightly cron trigger.
- **Risk:** self-hosted-runner-on-a-public-repo exposure (fork PRs) is a new risk this pivot introduces that a GitHub-hosted large runner would not have had; mitigated per design.md D1b (repo approval setting + same-repo-only workflow condition, both required before the label trigger goes live).
