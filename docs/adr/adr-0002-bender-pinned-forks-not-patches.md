---
title: "ADR-0002: Dependency changes flow through Bender-pinned forks, not local patches"
status: "Accepted"
date: "2026-09-13"
authors: "Sergii Bidnyi (thesis author)"
tags: ["architecture", "decision", "dependencies", "rtl", "toolchain", "provenance"]
supersedes: ""
superseded_by: ""
---

## Status

**Accepted** — codified as a hard constraint in [`AGENTS.md`](../../AGENTS.md) on
2026-09-13 (`edebf24`) and first exercised end-to-end on 2026-09-28, when
Cheshire moved to `wortexx/cheshire` at tag `v0.3.1-newt.1` (`608ae79`). Recorded
retroactively on 2026-09-28. Inherits from
[ADR-0001](adr-0001-fork-basilisk-own-tooling.md).

## Context

[ADR-0001](adr-0001-fork-basilisk-own-tooling.md) established that this project
owns its tooling decisions. It did not say *how* a change to a third-party RTL
dependency is expressed. That question is live and recurring: the thesis work
modifies CVA6 and Cheshire by design, and the existing flow already carries a
dozen fixes to dependency sources.

The inherited mechanism was text patching at the pickle stage. What exists today
in [`target/ihp13/pickle/patches/`](../../target/ihp13/pickle/patches/) is six
`.patch` files, three `.sed` scripts, one `.append` fragment, and — worst of the
set — an in-place `sed` in
[`target/ihp13/pickle/pickle.mk`](../../target/ihp13/pickle/pickle.mk) that
rewrites CVA6's `ariane_pkg.sv` *inside the Bender checkout* before pickling.
Patches are applied to intermediate artifacts (the ~180 MB morty pickle, then
the svase output, then the sv2v output) with `patch -u` under a leading `-`, so
**failures are silently tolerated by design**.

Four properties of that mechanism made it untenable:

- **Silent decay.** A patch whose context drifts does not fail the build; it
  stops applying. A `.sed` rule that no longer matches is a no-op. The
  `bump-cheshire-v0-3-1` change had to verify every rule against the pickle
  precisely because nothing would have reported a dead one (D3, D7 — two rules
  were already dead and were deleted).
- **Design changes hide as workarounds.** `patches/sv2v/sv2v.sed` is one line:
  `s|rst_addr_q <= boot_addr_i;|rst_addr_q <= 64'h0000000002000000;|g`. That is a
  functional change to the core's reset address wearing the costume of a tool
  fix. Nothing errors if it is dropped.
- **No provenance.** A patch against a generated 180 MB file cannot be reviewed,
  attributed to an upstream construct, diffed against upstream, or carried
  forward across a dependency bump. It is also invisible to anything but the
  synthesis path — simulation and lint see unpatched sources, so the lanes
  disagree about what the design is.
- **It is coupled to a flow that is being deleted.** The patch tree lives at the
  morty/svase/sv2v stages. The `replace-svase-sv2v-with-read-slang` change
  removes those stages entirely; a spike found that of eleven patch rules only
  three address real RTL bugs and the rest work around constructs slang handles
  natively. The three survivors need a home that is not a stage that no longer
  exists.

Two further constraints shape the answer. Bender already resolves every
dependency by `git` URL plus `rev`/`version`, so a fork costs nothing structural
to point at. And unlike dormant Basilisk, upstream Cheshire and CVA6 *are*
maintained — so the choice is not fork-or-nothing but fork-now versus
wait-for-upstream.

## Decision

**A change to a third-party dependency's sources is made in a project fork,
pinned in `Bender.yml` by `git` + `rev`, and never as a patch against generated
or checked-out text.**

The rule, as it is applied:

- Fixes live in a fork under `wortexx/` and reach the build only through
  `Bender.yml`/`Bender.lock`. `bender path <dep>` checkouts are read-only; the
  Makefiles must not mutate them.
- **Branch from the upstream release tag, not from the fork's `main`.** The
  Cheshire fork's branch `newt/v0.3.1` is cut from upstream `v0.3.1` (`5c76406`)
  because the fork's `main` tracks upstream and sits 49 commits / ~12k lines
  ahead — merging it would drag an unrelated RTL update into the flow.
- **Tag with a dotted counter: `v<upstream-version>-newt.<N>`** (annotated), so
  semver precedence stays numeric and `newt.10` ranks above `newt.2`.
- **Pin with `rev: <tag>`, not `version:`.** Semver ranks the pre-release
  `0.3.1-newt.N` *below* `0.3.1`, and plain version ranges do not match
  pre-releases at all.
- **Prove the fix before committing it.** The Cheshire address-map rewrite was
  compiled and run on the target VM (0 errors, `helloworld.spm` passing) before
  anything was pushed.
- **The boundary is shared source versus tool invocation.** A tool-specific
  workaround belongs in that tool's argument file or driver script — `-nowarn`
  entries, frontend flags, defines. Only a change to RTL that all lanes consume
  goes to a fork. Editing shared sources for one lane's benefit is what breaks
  DUT parity, and is the thing this rule forbids.
- **Threshold**, per `AGENTS.md`: prefer a fork commit over anything beyond a
  one-line change. The rule is not "never touch text" — it is that the moment a
  fix has any substance, it goes where it can be reviewed and version-pinned.
- Forking does not foreclose upstreaming. A fork commit is a strictly better
  starting point for an upstream PR than a patch against a pickle, and the fork
  carries the fix in the meantime instead of blocking on review latency.

Scope: this ADR governs **RTL dependencies resolved by Bender**. EDA tool
versions are pinned separately, as `ARG`s in `docker/*/Dockerfile` — a different
mechanism for a different kind of artifact.

## Consequences

### Positive

- **POS-001**: Fixes become reviewable and attributable. A fork commit has a
  diff against a known upstream base, a message, and a tag — none of which a
  `.sed` rule against a generated file can have.
- **POS-002**: Failures become loud. A wrong `rev` fails resolution immediately;
  a drifted patch silently stops applying. This removes the entire class of
  "the fix quietly stopped being applied" bug.
- **POS-003**: All lanes see the same design. Synthesis, Verilator, Xcelium and
  lint consume identical sources, so DUT parity holds by construction rather
  than by remembering to patch each path.
- **POS-004**: Reproducibility strengthens. `Bender.lock` records an exact
  revision per dependency, so the RTL is reconstructible from a commit —
  the same property ADR-0001 requires of tool versions.
- **POS-005**: Disguised design changes surface. Under this rule the reset-address
  override cannot masquerade as a tool workaround; it must be a commit with a
  stated intent, or be dropped deliberately.
- **POS-006**: It unblocks the frontend replacement. The three surviving RTL
  fixes have a home that does not depend on the morty/svase/sv2v stages, so
  `replace-svase-sv2v-with-read-slang` can delete those stages cleanly.
- **POS-007**: It is the right substrate for the thesis work itself. CV-X-IF
  enablement and the SHA instructions are multi-file changes to CVA6 and
  Cheshire; a Cheshire fork was going to be needed regardless.

### Negative

- **NEG-001**: Fork maintenance is now a standing cost. Each fork needs a branch
  cut from the right base, an annotated tag per iteration, a push, a re-pin and
  a re-lock. A fix that was a 30-second `sed` is now a multi-step release.
- **NEG-002**: Rebasing onto a new upstream release is real work, and it grows
  with the delta. The choice to branch from `v0.3.1` rather than fork `main`
  already reflects how quickly that divergence becomes unmanageable.
- **NEG-003**: The build now depends on repositories under a personal account.
  If `wortexx/cheshire` becomes unavailable or its history is rewritten, the
  flow cannot resolve — an availability and bus-factor risk the patch tree did
  not have.
- **NEG-004**: `rev: <tag>` pinning gives up version-range resolution for that
  dependency, so transitive compatibility must be reasoned about by hand. The
  Cheshire bump already had to hold `apb_uart` at 0.2.1 explicitly (D6) and lock
  the subtree to Cheshire's own tested lock (D2).
- **NEG-005**: Operational friction is real, not theoretical. Pushing the
  Cheshire branch over HTTPS was refused because the `gh` token lacks `workflow`
  scope (the v0.3.1 base carries `.github/workflows/*`); the push had to go over
  SSH.
- **NEG-006**: The shared-source-versus-tool-flag boundary requires judgment on
  every occurrence, and the cheap side is the tempting one. A `-nowarn` that
  should have been an RTL fix is this rule's characteristic failure mode.
- **NEG-007**: Forks are one more thing to keep current for security and
  correctness, with no one else watching them.

## Alternatives Considered

### Keep the pickle-stage patch tree (status quo)

- **ALT-001**: **Description**: Continue expressing dependency fixes as
  `.patch`/`.sed`/`.append` files applied to the morty, svase and sv2v outputs.
- **ALT-001**: **Rejection Reason**: Every property that makes it cheap also
  makes it unsafe — failures are tolerated by design, rules die silently, and
  patching a generated 180 MB artifact is unreviewable. It is also only applied
  on the synthesis path, so the lanes disagree about the design, and it is
  anchored to stages that `replace-svase-sv2v-with-read-slang` deletes.

### Patch the Bender checkout in place from the Makefile

- **ALT-002**: **Description**: Extend the existing `rtl-patches` pattern —
  `sed -i` against `$(bender path <dep>)` — to cover new fixes. Unlike ALT-001
  this at least reaches every lane.
- **ALT-002**: **Rejection Reason**: The worst variant of all. It mutates a
  cache Bender considers immutable, so the same checkout is correct or corrupt
  depending on whether a Makefile ran; `Bender.lock` then names a revision whose
  content on disk is not that revision. It destroys the one guarantee the lock
  file exists to provide.

### Vendor the dependency sources into this repository

- **ALT-003**: **Description**: Copy the RTL of modified dependencies in-tree
  and edit it directly, dropping the Bender reference.
- **ALT-003**: **Rejection Reason**: Fixes provenance by discarding it. Upstream
  history, blame and any future bump are lost, and the diff against upstream —
  the thing a reviewer and the thesis both need — becomes unrecoverable. It also
  makes every dependency update a manual re-vendoring.

### Upstream the fix and wait

- **ALT-004**: **Description**: Send each fix to `pulp-platform` and pin an
  upstream revision once merged. Viable here in a way it is not for Basilisk:
  Cheshire and CVA6 are actively maintained.
- **ALT-004**: **Rejection Reason**: Review latency is unbounded relative to the
  thesis schedule, and some fixes are not upstreamable as-is — the Xcelium
  address-map rewrite works around one simulator's restriction on constant
  functions for code that is legal SystemVerilog and that Questa, VCS, Verilator
  and slang all accept. Rejected as the *blocking* mechanism only; upstreaming
  from a fork commit stays available and is strictly easier than from a patch.

### Patch-queue tooling (quilt-style overlay)

- **ALT-005**: **Description**: Keep patches, but manage them with a tool that
  enforces application and tracks refresh — a patch series over a pinned
  upstream checkout.
- **ALT-005**: **Rejection Reason**: Buys back loudness but keeps the
  indirection, and adds a tool to the flow to reimplement what git already does.
  Given that forks were needed for the thesis work anyway, it would mean
  maintaining two mechanisms for one job.

## Implementation Notes

- **IMP-001**: Current state — Cheshire is pinned to
  `https://github.com/wortexx/cheshire.git` at `rev: v0.3.1-newt.1` (revision
  `465e9e8a`). CVA6 (`9338c2ca`) and `serial_link` (`5a25f5a7`) still resolve to
  upstream, so the three surviving RTL fixes for those two are the next forks to
  cut, under `replace-svase-sv2v-with-read-slang`: a negative-width replication
  in CVA6's `wt_axi_adapter`, and a non-`if`/`else` asynchronous-reset flop in
  `serial_link_physical`. The `cheshire_pkg` assignment-pattern fix belongs in
  the existing fork.
- **IMP-002**: Each fork pin carries a comment in `Bender.yml` stating what the
  fork adds, the branch it lives on, and the OpenSpec change that justifies it —
  the pattern the Cheshire and `apb_uart` entries already follow. A bare `rev:`
  with no comment is not acceptable.
- **IMP-003**: Migration is incremental and rides existing changes, not a
  flag-day. `xcelium-sim-lane` established the mechanism; the frontend
  replacement retires most of the patch tree and relocates the remainder. The
  in-place `rtl-patches` `sed` against `ariane_pkg.sv` must go in the same pass —
  it is the clearest violation remaining.
- **IMP-004**: The reset-address override needs an explicit decision, not a
  migration. Either it is a design choice and becomes a fork commit with a
  stated rationale, or it is dropped. Silently carrying it forward is the one
  outcome this ADR exists to prevent.
- **IMP-005**: Any RTL fix is proven in the environment that rejected it before
  the tag is cut, and the evidence goes in the change's design doc.
- **IMP-006**: Success criteria — `target/ihp13/pickle/patches/` is empty or
  gone; no Makefile writes into a `bender path` checkout; every dependency
  deviation from upstream is reachable as a fork commit named by a tag in
  `Bender.yml`.
- **IMP-007**: Reversal condition — if fork maintenance overtakes its benefit
  (many forks, frequent upstream bumps), the response is to shrink the delta by
  upstreaming, not to return to patching. Reinstating a patch mechanism requires
  a superseding ADR.

## References

- **REF-001**: [ADR-0001: Fork Basilisk and own all tooling decisions locally](adr-0001-fork-basilisk-own-tooling.md)
  — the parent decision; this ADR answers the "how" it left open.
- **REF-002**: [`AGENTS.md`](../../AGENTS.md) — "Hard constraints", where the
  forks-not-patches rule and the one-line threshold are stated.
- **REF-003**: [`openspec/changes/archive/2026-09-28-xcelium-sim-lane/design.md`](../../openspec/changes/archive/2026-09-28-xcelium-sim-lane/design.md)
  D7 — the first application: the Cheshire fork, its branch/tag/pin mechanics,
  and the rejection of a bundle-local patch on parity grounds.
- **REF-004**: [`openspec/changes/archive/2026-09-28-bump-cheshire-v0-3-1/design.md`](../../openspec/changes/archive/2026-09-28-bump-cheshire-v0-3-1/design.md)
  D2/D3/D6/D7 — subtree locking, verifying patch rules against the pickle, the
  `apb_uart` hold, and the deletion of already-dead rules.
- **REF-005**: [`openspec/changes/replace-svase-sv2v-with-read-slang/proposal.md`](../../openspec/changes/replace-svase-sv2v-with-read-slang/proposal.md)
  — the eleven-rule audit, the three surviving RTL fixes, and the reset-address
  override called out as a design change disguised as a workaround.
- **REF-006**: [`Bender.yml`](../../Bender.yml) / [`Bender.lock`](../../Bender.lock)
  — the pinning surface this decision routes everything through.
- **REF-007**: [`target/ihp13/pickle/pickle.mk`](../../target/ihp13/pickle/pickle.mk)
  and [`target/ihp13/pickle/patches/`](../../target/ihp13/pickle/patches/) — the
  mechanism being retired, including the `apply-patches` macro's tolerated
  failures.
