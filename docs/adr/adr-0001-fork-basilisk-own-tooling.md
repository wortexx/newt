---
title: "ADR-0001: Fork Basilisk and own all tooling decisions locally"
status: "Accepted"
date: "2026-08-29"
authors: "Sergii Bidnyi (thesis author)"
tags: ["architecture", "decision", "project-foundation", "toolchain", "dependencies"]
supersedes: ""
superseded_by: ""
---

## Status

**Accepted** — in force since the fork point (`89c6c3f`, 2026-08-29). Recorded
retroactively on 2026-09-20; the decision predates this document and every
consequence listed below has already been realized.

## Context

The thesis adds SHA cryptography instructions to a CVA6-based SoC and carries
them end-to-end through a real open-source synthesis and place-and-route flow to
obtain silicon-realistic PPA numbers on IHP's SG13G2 130 nm open PDK. The only
existing codebase that does the whole path — RV64 Linux-capable SoC, IHP13
technology wrappers, Yosys synthesis, OpenROAD backend, tape-out-shaped
constraints — is Basilisk (`pulp-platform/cheshire-ihp130-o`, internally
`iguana_chip`). Rebuilding that integration from Cheshire alone was never a
realistic use of thesis time.

The forces at play at the start of the project:

- **Upstream is dormant.** The last upstream commit is `560f00f` (2024-10-01,
  "hw: fix vga RGB widths"); the published tooling image was built 2024-08-22.
  There is no evidence of an active maintainer and no response path for fixes.
- **The tooling had visibly rotted.** OpenROAD was pinned at `589dee1c8`
  (~mid-2024), roughly a 2.5-year API gap. Yosys was a *custom fork* (upstream
  2024-04 plus three commits on `abc.cc`) with no upstream tracking. `svase` is
  archived upstream. Simulation was Questa-only, with no open-source path.
- **The work is inherently invasive.** Adding instructions touches CVA6 and
  Cheshire, the pickle/synthesis frontend, the netlist naming contract the
  OpenROAD scripts depend on, the simulator, and the software build. Almost none
  of it is upstreamable as isolated patches.
- **Thesis work needs reproducibility and a schedule.** Results must be
  reconstructible from a commit, and the project cannot have its critical path
  blocked on an unresponsive third party.
- **The project is single-maintainer**, with no organizational requirement to
  stay aligned with upstream and no obligation to contribute changes back.

The question this ADR settles: does `newt` track upstream Basilisk and route
changes through it, or does it fork and assume full ownership of every tooling
and flow decision going forward?

## Decision

`newt` (`wortexx/newt`) is a **hard fork** of Basilisk that **owns all tooling,
flow, and dependency decisions locally**. Upstream is treated as a historical
starting point, not as an authority, a source of fixes, or a merge target.

Concretely:

- The fork retains full upstream git history (commits back to 2023-02-20), so
  provenance and blame remain intact, but diverges permanently at `89c6c3f`
  (2026-08-29). No upstream merges are expected or planned.
- Every external tool version is chosen, pinned, and bumped by this project on
  its own evidence — not inherited. Tool versions live in the repository
  (`docker/*/Dockerfile`, `tools.mk`, `Bender.yml`/`Bender.lock`).
- Broken or stale upstream tooling is replaced rather than worked around while
  waiting: the project may retire an upstream fork (Yosys), bump a backend
  across a multi-year API gap (OpenROAD), replace a frontend outright
  (`svase`/`sv2v` → `read_slang`), or add a missing capability (Verilator).
- Because there is no upstream review, the project supplies its own: changes are
  proposed, designed, and archived as OpenSpec artifacts under `openspec/`, and
  expensive flow changes are validated against explicit adoption gates and a
  checked-in synthesis baseline.
- "We own it" is a responsibility, not only a permission — every inherited
  defect is this project's to fix, on this project's schedule.

The rationale is that the cost of ownership was going to be paid regardless. An
unresponsive upstream converts every "wait for upstream" into an indefinite
block, and the thesis has a fixed deadline. Making ownership explicit at the
start means the tooling debt is paid deliberately and recorded, rather than
discovered mid-flow.

## Consequences

### Positive

- **POS-001**: Removes the project's single largest schedule risk. No change —
  toolchain, RTL, or flow — can be blocked by a third party who has not
  committed in two years.
- **POS-002**: Enables the tooling modernization the thesis actually requires.
  OpenROAD moved to `2c56926` (2026-08-27), Yosys moved from a custom fork to
  upstream v0.69 (retiring a maintenance surface entirely), a reproducible
  multi-stage `newt-eda` image replaced the 2024 published image, and the
  `svase`+`sv2v` frontend can be replaced with `read_slang`. None of these were
  available on an upstream-tracking path.
- **POS-003**: Makes reproducibility a property of the repository. Every tool
  version is `ARG`-pinned and reconstructible from a commit, which is a hard
  requirement for defensible PPA numbers in a thesis.
- **POS-004**: Permits changes that are structurally un-upstreamable — enabling
  CV-X-IF, altering the netlist naming contract, restructuring the P&R flow into
  stage-per-process with checkpoint/resume — without negotiating scope with a
  maintainer.
- **POS-005**: Frees the project to add infrastructure upstream never had (CI
  lanes, Azure IaC, an open simulation path) without arguing that it belongs in
  a shared codebase.

### Negative

- **NEG-001**: No inbound fixes. Any bug, security issue, or PDK update that a
  live upstream would have absorbed is now this project's to find and fix.
- **NEG-002**: The inherited tooling debt became a direct, unplanned cost. The
  OpenROAD bump alone required real porting work across a 2.5-year API gap
  (`initialize_floorplan -sites`→`-site`; `detailed_route`'s
  `-bottom/-top_routing_layer` now hard-error as DRT-0509/0510; PDN zero-instance
  crashes; per-process `set_wire_rc`/`estimate_parasitics`/`set_thread_count`) —
  work that produced no thesis result on its own.
- **NEG-003**: Single-maintainer bus factor with no external review. Mitigated
  only by self-imposed process (OpenSpec artifacts, adoption gates, the
  `synth-baseline.json` regression gate), which costs time on every change.
- **NEG-004**: Divergence is effectively permanent. If upstream revives, merging
  back becomes progressively harder; after a frontend replacement and a P&R
  restructure it is realistically out of reach.
- **NEG-005**: Inherited naming debt is now frozen in place. `PROJ_NAME`/
  `RTL_NAME` must stay `basilisk` while the design is internally `iguana_chip`
  and scripts use `ig-` prefixes — a permanent legibility cost that no upstream
  cleanup will ever resolve.
- **NEG-006**: Improvements made here (the OpenROAD port, the Yosys migration,
  the Verilator flow) benefit no one else unless separately upstreamed, which is
  not planned.

## Alternatives Considered

### Track upstream and contribute changes back

- **ALT-001**: **Description**: Work against `pulp-platform/cheshire-ihp130-o`,
  keep a thin local delta, and submit tooling fixes as pull requests upstream.
- **ALT-001**: **Rejection Reason**: There is no one to merge them. Upstream's
  last commit is 2024-10-01 and the image predates it. This path makes the
  thesis's critical path depend on a party with no demonstrated response time,
  and most of the required changes (frontend replacement, netlist naming
  contract, CV-X-IF enablement) are not isolated patches anyone would accept as
  such.

### Fork, but keep tooling as inherited and change only the RTL

- **ALT-002**: **Description**: Fork for the ISA work, but treat the 2024 Docker
  image, the Yosys fork, and the `svase`/`sv2v` frontend as fixed infrastructure
  and build only on top of them.
- **ALT-002**: **Rejection Reason**: The inherited flow does not meet the
  thesis's requirements. It has no open simulation path (Questa-only), does not
  complete P&R unattended, cannot be reproduced from a commit, and its frontend
  depends on an archived tool that will never be fixed. Deferring these
  decisions does not avoid their cost; it relocates it to the point where the
  ISA work is already in flight.

### Start from vanilla Cheshire and build the IHP13 target fresh

- **ALT-003**: **Description**: Take upstream Cheshire, which is maintained, and
  construct the IHP13 technology wrappers, SDC constraints, Yosys scripts, and
  OpenROAD flow from scratch.
- **ALT-003**: **Rejection Reason**: Discards the one asset that makes the
  thesis feasible — a working end-to-end ASIC flow on a real open PDK. The
  backend flow, pad ring, macro placement, and constraints represent far more
  effort than the thesis has available, and rebuilding them is not a thesis
  contribution.

### Vendor upstream as a submodule with an overlay repository

- **ALT-004**: **Description**: Keep upstream Basilisk pristine as a submodule
  and layer all changes as an overlay of patches and replacement scripts.
- **ALT-004**: **Rejection Reason**: Optimizes for merging from an upstream that
  will never publish again, and pays for it with a permanently indirect
  codebase. It also entrenches exactly the mechanism this project has since
  chosen to retire — patching generated or third-party text instead of owning a
  pinned source of truth.

### Do nothing / defer the ownership question

- **ALT-005**: **Description**: Begin the ISA work without settling the
  relationship to upstream, and decide case by case.
- **ALT-005**: **Rejection Reason**: Deferral is itself a decision to wait, and
  waiting has no terminating condition here. Each unresolved tooling failure
  would be re-litigated under schedule pressure, with the least time available
  to do it well.

## Implementation Notes

- **IMP-001**: Fork point is `89c6c3f` (2026-08-29) on `wortexx/newt`, with full
  upstream history retained back to 2023-02-20. Upstream's final commit,
  `560f00f` (2024-10-01), is the last shared ancestor.
- **IMP-002**: Ownership is expressed through pinning, not through vendoring.
  Tool versions are `ARG`-pinned in `docker/*/Dockerfile` with immutable
  date+sha image tags; RTL dependencies are pinned by `git`/`rev` in
  `Bender.yml`/`Bender.lock`. Dependency changes go through pinned forks rather
  than local patches (its own decision, to be recorded separately).
- **IMP-003**: Ownership is bounded by gates, not by taste. Tool bumps that move
  synthesis results must re-run the synthesis adoption gate and reseed
  `target/ihp13/yosys/synth-baseline.json` with a measured before/after; a green
  build alone is not sufficient evidence.
- **IMP-004**: The self-review substitute is OpenSpec. Every non-trivial change
  carries a proposal, a design with numbered decisions, and tasks, archived
  under `openspec/changes/archive/` on completion. This ADR set is the
  higher-altitude index over those artifacts.
- **IMP-005**: `AGENTS.md` and `docs/infra-plan.md` are the living surfaces of
  this decision and must state the ownership stance explicitly, since both
  humans and coding agents otherwise default to "check whether upstream fixed
  it."
- **IMP-006**: Success criteria — the flow builds and runs from a clean clone at
  a pinned commit; no work item is ever blocked pending upstream; and every tool
  version in use is traceable to a deliberate, recorded choice in this
  repository.
- **IMP-007**: Reversal condition — if upstream revives with an active
  maintainer, the response is selective cherry-picking of upstream fixes, not a
  merge. A return to upstream tracking would require a superseding ADR.

## References

- **REF-001**: [`AGENTS.md`](../../AGENTS.md) — project overview, hard
  constraints, and the statement that this fork owns all tooling decisions.
- **REF-002**: [`docs/infra-plan.md`](../infra-plan.md) §0 "Context &
  constraints" — the dormancy, tool-rot, and resource facts this decision rests
  on, and the phase-by-phase record of the debt being paid down.
- **REF-003**: [`docs/custom-isa-extension.md`](../custom-isa-extension.md) —
  the thesis goal that makes an invasive, un-upstreamable change set necessary.
- **REF-004**: Upstream Basilisk —
  `https://github.com/pulp-platform/cheshire-ihp130-o` (last commit `560f00f`,
  2024-10-01).
- **REF-005**: Cheshire — `https://github.com/pulp-platform/cheshire` — the
  upstream toolkit Basilisk itself derives from.
- **REF-006**: Downstream decisions that inherit from this one and are recorded
  separately: dependency changes via Bender-pinned forks; the `newt-eda` image
  as the sole tooling boundary; Yosys upstream replacing the custom fork
  ([`openspec/changes/archive/2026-09-18-upgrade-yosys-upstream/`](../../openspec/changes/archive/2026-09-18-upgrade-yosys-upstream/));
  the `svase`+`sv2v` → `read_slang` frontend replacement
  ([`openspec/changes/replace-svase-sv2v-with-read-slang/`](../../openspec/changes/replace-svase-sv2v-with-read-slang/)).
- **REF-007**: Licensing inherited from upstream and unchanged by the fork —
  Solderpad Hardware License 0.51 for hardware and tool scripts, Apache-2.0 for
  software (see [`LICENSE`](../../LICENSE)).
