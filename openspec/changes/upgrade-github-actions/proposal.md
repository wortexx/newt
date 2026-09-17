# Upgrade GitHub Actions dependencies

## Why

Every third-party action this repository uses is behind its current major — `actions/checkout` and `actions/upload-artifact` by three majors each (v4 → v7), `docker/*` and `azure/login` by one each. Nothing in the repository watches these dependencies, so the drift accumulated silently and will keep accumulating. The v4-era releases run on Node 20, whose upstream support has ended; GitHub has been progressively forcing Node 20 actions onto the Node 24 runtime, which means the pinned-to-old-major lanes are exposed to a runtime swap we do not control and cannot schedule. Doing the move deliberately, once, is cheaper than discovering it when the P&R lane fails 20 hours into a run.

Flow stages touched: **CI only**. No RTL, sim, synth-script, backend-script, or software source is modified — only workflow definitions under `.github/`.

## What Changes

- Bump all six actions in `.github/workflows/` to their current major:
  - `actions/checkout` v4 → v7 (9 call sites across `ci.yml`, `infra.yml`, `pnr.yml`, `synth.yml`)
  - `actions/upload-artifact` v4 → v7 (4 call sites across `pnr.yml`, `synth.yml`)
  - `azure/login` v2 → v3 (5 call sites across `pnr.yml`, `vm-watchdog.yml`)
  - `docker/build-push-action` v6 → v7 (6 call sites in `docker-image.yml`)
  - `docker/setup-buildx-action` v3 → v4 (1 call site)
  - `docker/login-action` v3 → v4 (1 call site)
- Pin every **third-party** action (`docker/*`, `azure/login`) to a full 40-character commit SHA with a trailing `# vX.Y.Z` comment, so a compromised or retagged upstream release cannot silently change what runs in CI. First-party `actions/*` stay on major tags.
- Add `.github/dependabot.yml` with a `github-actions` ecosystem entry so future action releases arrive as reviewable pull requests instead of as three-major drift.
- Verify the self-hosted synth/P&R runner satisfies the new Node 24 floor (Actions Runner ≥ 2.327.1) on its next lane run.

**Not breaking** for any consumer: no workflow trigger, input, output, artifact name, or required status check changes. The behavioural surface of CI is intended to be bit-identical before and after.

## Capabilities

### New Capabilities

None. This change adds no new CI lane, job, or gate.

### Modified Capabilities

- `ci-pipeline`: adds two requirements governing how workflows reference their action dependencies — a SHA-pinning policy for third-party actions, and automated dependency-update coverage for the `github-actions` ecosystem. Both are externally observable properties of the pipeline's supply chain, not implementation details, and neither is expressible today. No existing requirement's behaviour changes.

## Impact

**Modified files**

- `.github/workflows/ci.yml` — 5 `checkout` refs
- `.github/workflows/docker-image.yml` — 6 `build-push-action`, 1 `setup-buildx-action`, 1 `login-action`, 1 `checkout`
- `.github/workflows/infra.yml` — 1 `checkout`
- `.github/workflows/pnr.yml` — 1 `checkout`, 2 `upload-artifact`, 4 `azure/login`
- `.github/workflows/synth.yml` — 1 `checkout`, 2 `upload-artifact`
- `.github/workflows/vm-watchdog.yml` — 1 `azure/login`
- `.github/dependabot.yml` — new file

**Dependencies and systems**

- *Node 24 runtime floor.* Every one of these majors is fundamentally the same change: `runs.using: node24`, requiring Actions Runner ≥ 2.327.1. GitHub-hosted runners are already past that. The self-hosted `newt-synth-runner` is installed by `infra/azure/provision-runner.sh`, which fetches the latest `actions/runner` release, and repository runners self-update by default — so it is very likely already compliant, but it is currently offline (VM deallocated by design) and cannot be checked without starting it. This is the change's one real risk and is carried as an explicit verification task on the next synth/P&R run.
- *Container jobs.* `ci.yml`, `synth.yml`, and the `pnr` job run inside `ghcr.io/wortexx/newt-eda:dev`, built on `ubuntu:24.04` (glibc 2.39). The runner injects its own Node binary into the container; glibc 2.39 is comfortably above the node24 floor, so no image rebuild is needed.
- *No affected deprecations.* `docker/build-push-action` v7 drops `DOCKER_BUILD_NO_SUMMARY` and `DOCKER_BUILD_EXPORT_RETENTION_DAYS`; neither appears anywhere in `.github/`. `setup-buildx-action` v4 drops deprecated inputs; the single call site passes none. All four `upload-artifact` call sites use only `name`, `path`, `retention-days`, and `if-no-files-found`, all still supported in v7.
- *`checkout` v7's fork-PR block.* v7 refuses to check out a fork PR head under `pull_request_target` and `workflow_run`. No workflow in this repository uses either trigger, so this is inert here.
- *Cost.* Validation is CI-only and cheap for the hosted lanes. The synth and P&R lanes are expensive (~2.5 h and >24 h respectively) and are not run as a gate for this change; their verification rides on their next scheduled or dispatched run.

**Explicitly out of scope**

- Bumping the `newt-eda` base image, EDA tool versions, or any Bender-pinned RTL dependency.
- Changing which checks are required, which lanes gate merges, or any workflow trigger.
- Pinning first-party `actions/*` to SHAs.
