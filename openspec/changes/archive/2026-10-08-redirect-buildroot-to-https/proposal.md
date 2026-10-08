## Why

Every lane's first dependency checkout clones Cheshire with all of its submodules, recursively.
One of them is `sw/deps/cva6-sdk`, whose own `buildroot` submodule points at the legacy
`git://git.buildroot.net/buildroot`. That server has had two full outages in two days
(2026-10-06 and 2026-10-07). Each time it reset every connection, and each time every
fast-lane job failed (PRs #63 and #64), along with the P&R dispatch `37512872714`'s first attempt.
The workflows' 3-attempt retry was written for one-off connection resets. It cannot get past an
outage that lasts hours.

None of that content is used. In Cheshire, `cva6-sdk` only builds the Linux boot images
(`linux.*.gpt.bin`), which no newt target produces. It is cloned only because Bender checks out
dependency submodules recursively. The same buildroot commit the pins need (`aa433d1c`, traced
from `Bender.lock` → `cheshire@7b53138` → `cva6-sdk@55c1371`) is served over HTTPS by
buildroot's own GitLab project, `https://gitlab.com/buildroot.org/buildroot.git`. A git URL
rewrite redirects the nested clone there, and it was verified during the 2026-10-07 outage: the
`git://` URL resets, the rewritten one clones `aa433d1c`.

## What Changes

- **CI**: a workflow-level git URL rewrite in `ci.yml`, `synth.yml` and `pnr.yml`, set through
  `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_0` / `GIT_CONFIG_VALUE_0`:
  `url.https://gitlab.com/buildroot.org/buildroot.git.insteadOf = git://git.buildroot.net/buildroot`.
  Bender calls the system `git`, which reads these variables, so every clone in every job
  (including inside the `newt-eda` container) fetches buildroot over HTTPS. The retry helpers stay
  in place for transient faults on any other remote. Their comments, which name buildroot as the
  cause, are updated.
- **Docs**: `AGENTS.md`'s tool setup gains the one-line `git config --global` equivalent for
  local and `use-docker.sh` users, who hit the same clone.
- **Plan**: `docs/infra-plan.md` gains an optional phase for the durable fix (workaround B). The
  Cheshire fork's next tag, `newt.3`, drops the unused `cva6-sdk` submodule or points it at
  HTTPS, alongside Phase 16's planned crt0/bootrom fix. It costs one re-synthesis (`Bender.lock`
  is a synth cache key input). It is not part of this change.

Flow stages touched: **CI** only. No RTL, sim, synth, backend or sw change, and no synth cache
key input changes (`.github/` is not one).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `ci-pipeline`: a new requirement that the CI lanes' dependency checkout does not depend on the
  legacy `git://git.buildroot.net` server.

## Impact

- **Code**: `.github/workflows/ci.yml`, `synth.yml`, `pnr.yml` (an `env:` block each, plus
  retry-comment updates). `AGENTS.md` and `docs/infra-plan.md` (text).
- **Dependencies**: buildroot is now fetched from `gitlab.com/buildroot.org`, buildroot's own
  current upstream, instead of `git.buildroot.net`. Same commit, so the checked-out tree is
  identical.
- **Results**: none. The synth cache keys, netlists and P&R checkpoints are unaffected.
- **Not covered**: refs that predate the change, such as the `measure/grt-repair-*` branches and
  old tags, still use the `git://` URL until they are rebased or the B fix lands. Only the B fix
  removes the clone itself.
- **Cost**: GitHub-hosted CI only. No VM time is needed to validate it: the fast lane exercises
  the same checkout, and the self-hosted lanes get it on their next scheduled run.
