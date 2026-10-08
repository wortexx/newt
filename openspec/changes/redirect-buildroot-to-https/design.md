## Context

See proposal.md for why. The facts that shape the approach:

- **The clone is nested and not ours.** `wortexx/cheshire@7b53138` (`v0.3.1-newt.2`) has two
  submodules, `sw/deps/printf` and `sw/deps/cva6-sdk`. `pulp-platform/cva6-sdk@55c1371` in turn
  has `buildroot` → `git://git.buildroot.net/buildroot` at `aa433d1c`, plus opensbi, u-boot,
  riscv-isa-sim, riscv-tests and vitetris over HTTPS. Bender initializes them recursively. No
  newt target uses `cva6-sdk`: Cheshire's `sw.mk` needs it only for `linux.*.gpt.bin`.
- **Where the checkout happens.** All five `ci.yml` jobs (`lint`'s `bender sources`, then
  `ig-sw-all`, `ig-hw-cva6` and the block-synth makes), `synth.yml`'s and `pnr.yml`'s
  `ig-hw-all`. Each is wrapped in the same 3-attempt `retry` helper, and each runs inside the
  `newt-eda` job container.
- **No `GIT_CONFIG_*` use today.** No workflow sets `GIT_CONFIG_COUNT` or its keys, and
  `pnr.yml` is the only one of the three with a workflow-level `env:` block.
- **Verified on 2026-10-07, during the outage.** With the three variables set, `git ls-remote`
  on the `git://` URL answers from GitLab, and a fresh `cva6-sdk@55c1371` clone with
  `git submodule update --init buildroot` checks out `aa433d1c`. Without them, every connection
  is reset. `git ls-remote --get-url <url>` prints the rewritten URL offline. The
  `newt-eda:dev` image ships git 2.43, and the variables work inside it (checked with
  `docker run -e GIT_CONFIG_…`).

## Goals / Non-Goals

**Goals:**

- No CI lane depends on `git.buildroot.net` for its dependency checkout.
- A lane that somehow loses the redirect fails immediately and says why, rather than failing
  three retries later on a clone error.

**Non-Goals:**

- Removing the `cva6-sdk` clone. That is workaround B, recorded as an optional phase in the infra
  plan, and it needs a Cheshire fork tag and a re-synthesis.
- Fixing refs that predate this change (old tags, the `measure/grt-repair-*` branches).
- Changing local developer machines. `AGENTS.md` documents the one-liner, but nothing enforces
  it.
- Mirroring or vendoring any other dependency.

## Decisions

### D1. `GIT_CONFIG_*` environment variables at workflow level

Each of `ci.yml`, `synth.yml` and `pnr.yml` gets three variables in a top-level `env:` block
(`pnr.yml` extends its existing one):

```yaml
GIT_CONFIG_COUNT: '1'
GIT_CONFIG_KEY_0: url.https://gitlab.com/buildroot.org/buildroot.git.insteadOf
GIT_CONFIG_VALUE_0: git://git.buildroot.net/buildroot
```

Git reads these as if they were in the configuration (git ≥ 2.31). Workflow-level `env:`
reaches every `run:` step, including steps in a job container. Bender spawns `git` as a child
process, so the variables reach the recursive submodule clone, and `insteadOf` applies to
submodule URLs taken from `.gitmodules`.

*Alternatives.*
- A `git config --global` step in each job. It needs one step per job (seven today: five in `ci.yml`, plus `synth.yml`'s and `pnr.yml`'s), and a new job
  that forgets it regresses silently.
- `/etc/gitconfig` in the `newt-eda` image. It would also fix old refs and local Docker users, but
  the setting would be invisible in the workflows, and landing it needs an image rebuild. The
  image's smoke test could assert it, but it is a bigger change for the same effect in CI.

### D2. Buildroot's GitLab project as the target

`https://gitlab.com/buildroot.org/buildroot.git` is buildroot's own project, not a third-party
mirror, and it holds the pinned `aa433d1c` (verified). Only the exact URL is rewritten, the
`git://` form found in `cva6-sdk`'s `.gitmodules`. Other buildroot URLs are left alone.

*Alternative.* The read-only GitHub mirror of buildroot. It would also work, but it is a mirror
of the project above, so it is one hop further from the source.

### D3. Fail early if the redirect is missing

Each job that checks out dependencies gets a first step, before any `bender`/`make`, that runs
`git ls-remote --get-url git://git.buildroot.net/buildroot` and fails with a `::error::` naming
this change unless the result is the GitLab URL. The check is offline and takes milliseconds. It
turns a deleted or mistyped `env:` entry into an immediate, named failure instead of a
clone error three retries later. In `ci.yml` the step goes in each of the five jobs. A shared
composite action would be one more file for a one-liner, so the step is inlined.

### D4. Keep the retries and correct their comments

The `retry` helpers stay: other remotes can still drop a connection now and then. Their comments
name buildroot as *the* cause. They are updated to say that buildroot is now redirected (this
change) and that the retry covers transient faults on the remaining remotes.

## Risks / Trade-offs

- [buildroot's GitLab also goes down] → Same failure as today, through a different host. The
  durable answer is B (stop cloning it), recorded in the infra plan.
- [Some step sets `GIT_CONFIG_COUNT` itself, which replaces the block] → None does today. D3's
  check fails loudly if it ever happens before the checkout.
- [An action uses `GIT_CONFIG_*` internally, e.g. `actions/checkout`] → Checkout runs before
  `bender`. The only effect would be our redirect applying to its fetch, which never touches
  buildroot. The fast lane exercises this on the PR itself.
- [The self-hosted lanes only exercise it on their next scheduled run] → The variables and the
  check are identical across the three workflows, and the fast lane proves them on the PR. A
  dedicated P&R dispatch would not be cheap: on `main` it would re-synthesize first (~2.5 h), so
  the nightly synth run and the weekly P&R run are the check.

## Migration Plan

Merge, and the next run of each lane picks it up. Rollback is reverting the commit, which brings
back the dependency on `git.buildroot.net`. B, when it lands, makes this redundant. The variables
can then stay as a harmless backstop or be removed.
