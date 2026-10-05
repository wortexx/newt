---
title: "ADR-0004: Keep CVA6's hypervisor extension (H) on in the thesis baseline"
status: "Accepted"
date: "2026-10-02"
authors: "Sergii Bidnyi (thesis author)"
tags: ["architecture", "decision", "cva6", "cheshire", "baseline", "ppa", "thesis-scope"]
supersedes: ""
superseded_by: ""
---

## Status

**Accepted** on 2026-10-02. It resolves the open decision in
[`docs/infra-plan.md`](../infra-plan.md) Phase 15: whether the thesis baseline
should turn H off. It is also the prerequisite of task 5.3 (SoC synthesis) in
the OpenSpec change
[`sha3-cvxif-coprocessor`](../../openspec/changes/archive/2026-10-05-sha3-cvxif-coprocessor/).

## Context

CVA6 is configured at two layers (infra-plan Phase 15):

- **Package constants** in `cv64a6_imafdcsclic_sv39_config_pkg.sv`, which
  `iguana.mk`'s `IG_CVA6_PKG_PARAMS` rewrites (cache sizes, D-cache type,
  scoreboard entries, …).
- **The `cva6_cfg_t` struct** the core is actually instantiated with. Cheshire
  builds it in `gen_cva6_cfg()`. Upstream, that function hard-codes `RVH : 1`.

`iguana.mk` sets `CVA6ConfigHExtEn=0` with the comment "deactivate hypervisor
extension (large and not needed)". That only changes the package constant, so
**H has been on all along**. A Verilator probe of
`cheshire_pkg::gen_cva6_cfg(iguana_pkg::CheshireCfg)` gives `RVH=1`. The
revision Basilisk was forked at (`4a270af`, before the Cheshire v0.3.1 bump)
also has `RVH : 1`. Every number produced so far includes H:

- the synthesis baseline `target/ihp13/yosys/synth-baseline.json`
  (735,953 cells, 17.77 mm²);
- the P&R figures in `docs/infra-plan.md`;
- every SoC-level simulation, including the SHA-3 cycle counts in
  `docs/results/sha3-ise.md`.

Turning H off is possible without touching CVA6: a `cheshire_cfg_t` field in
the Cheshire fork (e.g. `Cva6RvhEn`, next to `Cva6CvxifEn`) can drive `RVH`.
Such a patch was prepared (fork tag `v0.3.1-newt.3`) and then withdrawn when
this decision was taken.

## Decision

**Keep the hypervisor extension on. The thesis baseline and every SoC-level
PPA figure, before and after the SHA-3 coprocessor, are measured on a CVA6
with `RVH = 1`, the configuration the project has always had.** newt stays
pinned to Cheshire fork tag `v0.3.1-newt.2`, which has no H field. The
misleading `CVA6ConfigHExtEn=0` comment in `iguana.mk` is corrected to say that
H stays on, and why.

## Consequences

### Positive

- **POS-001**: Baseline continuity. `synth-baseline.json`, the CI synthesis
  adoption gate and every PPA number recorded so far stay valid. Nothing has to
  be reseeded before the coprocessor's SoC delta (task 5.3) is measured.
- **POS-002**: No extra long runs. Reseeding would take a full SoC synthesis
  (~2.5 h, > 35 GB RAM), and a new P&R reference would take > 24 h.
- **POS-003**: The design stays the one Basilisk was forked as. Any comparison
  with Basilisk's published figures keeps the same core configuration.
- **POS-004**: No new dependency change and no new risk in the core or SoC
  boot path in the middle of the measurement campaign.

### Negative

- **NEG-001**: The baseline carries logic the thesis workloads never use:
  two-stage address translation, the virtual-supervisor CSRs and the related
  exception paths. Its size is not measured here.
- **NEG-002**: The coprocessor's area as a share of the SoC is diluted by H's
  area. Absolute deltas are unaffected; percentages must be stated against an
  H-on SoC.
- **NEG-003**: The H logic can sit on or near the core's critical paths, so the
  SoC timing figures describe an H-on core.

## Alternatives Considered

### Turn H off via the Cheshire fork

- **ALT-001**: **Description**: Add a `Cva6RvhEn` field to the Cheshire fork,
  set `ret.Cva6RvhEn = 0` in `iguana_pkg`, re-run the SoC regression, and reseed
  `synth-baseline.json` through the synthesis adoption gate before any
  coprocessor PPA delta is quoted.
- **ALT-001**: **Rejection Reason**: It moves the baseline in the middle of the
  measurement campaign. It costs a full SoC synthesis plus a regression run up
  front, invalidates the comparison with every number recorded so far, and adds
  a configuration Basilisk was never built in. The benefit, a smaller and
  possibly faster core, is not what the thesis measures: its contribution is
  the coprocessor's delta on a fixed baseline.

### Measure H's cost as a separate data point

- **ALT-002**: **Description**: Keep H on for the thesis, but also synthesize
  one H-off SoC to quantify H's area.
- **ALT-002**: **Rejection Reason**: Not needed for the thesis results, and it
  costs another full synthesis run. It remains possible later with the
  one-field fork patch of ALT-001.

## Implementation Notes

- **IMP-001**: newt's `Bender.yml` keeps `cheshire` at `v0.3.1-newt.2`. The
  `v0.3.1-newt.3` tag that carried `Cva6RvhEn` was deleted from the fork; the
  next fork release reuses the number.
- **IMP-002**: Results reports name the configuration: "CVA6
  `cv64a6_imafdcsclic_sv39`, H extension on (ADR-0004)".
- **IMP-003**: Reversal: switching H off later needs a superseding ADR, the
  fork field with `Cva6RvhEn = 0`, a re-run of the SoC regression, and a
  reseeded `synth-baseline.json` before any H-off figure is compared with an
  H-on one.

## References

- **REF-001**: [`docs/infra-plan.md`](../infra-plan.md) Phase 15
  (`IG_CVA6_PKG_PARAMS` only partly reaches the core).
- **REF-002**: Cheshire `hw/cheshire_pkg.sv` `gen_cva6_cfg()` (`RVH : 1`).
- **REF-003**: [ADR-0002](adr-0002-bender-pinned-forks-not-patches.md): the
  Cheshire fork as the place for dependency changes.
- **REF-004**: [ADR-0003](adr-0003-sha3-via-cvxif.md) and
  [`openspec/changes/archive/2026-10-05-sha3-cvxif-coprocessor/`](../../openspec/changes/archive/2026-10-05-sha3-cvxif-coprocessor/)
  (task 5.3).
