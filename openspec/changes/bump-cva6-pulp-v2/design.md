# Design

## Context

- CVA6 reaches newt only through Cheshire. Every Cheshire release (`v0.2.0` … `v0.3.1`) pins `pulp-v1.0.0`. Only Cheshire `main` pins `pulp-v2.0.0`, since `71f9cb2` (2025-10-07). `main` is 46 commits past `v0.3.1`, and the rest of it brings SystemRDL register files, `serial_link` 2.0.0, `axi_llc` 0.3.0, `clint` 0.3.0 and a new `apb` dependency.
- `pulp-v2.0.0`'s own dependencies are `axi` ^0.31, `common_cells` ^1.23, `fpnew` `pulp-v0.2.3` and `tech_cells_generic` ^0.2.13. The current lock already satisfies all except `fpnew`.
- The SHA-3 coprocessor branch is on the v1 CV-X-IF and stays there for now. This change must not depend on it.

## Goals / Non-Goals

**Goals**
- CVA6 at `pulp-v2.0.0` through a tagged Cheshire fork, with the smallest Cheshire delta that gets there.
- The CVA6 config the project declares in `iguana.mk` is the config that gets built.
- Every CVA6-keyed pickle rule and keep-hierarchy selector is re-checked, and the dead ones are removed.

**Non-Goals**
- Moving Cheshire to `main` or to a future release.
- Enabling CV-X-IF or Zkn, or porting `keccak_cvxif` to CV-X-IF 1.0.
- Reseeding `synth-baseline.json` without a measured before/after.

## Decisions

### D1. Cherry-pick `71f9cb2` onto the existing fork, not rebase onto Cheshire `main`
The commit touches 10 files. Its RTL hunks (`cheshire_pkg.sv`, `cheshire_soc.sv`) apply cleanly to `v0.3.1-newt.1`. The three conflicts are outside the IHP design:
- a Bender.yml context line (iDMA 0.6.3 vs 0.6.4, kept at 0.6.3);
- `CHS_NONFREE_COMMIT` (kept);
- the Xilinx top, where the hunk's context was an earlier `USE_CFG_REGS` commit that was not picked, so only the `USE_VCLIC` block is taken.

Rebasing onto `main` would bundle CVA6 with five unrelated subsystem moves and no release behind them.

The fork tag `v0.3.1-newt.2` keeps the `v<upstream>-newt.<N>` scheme, so its upstream base is still `v0.3.1`. The tag message lists both commits.

*Alternative rejected:* bump only the `cva6` line in the fork's Bender.yml. That fails, because v2 replaces `config_pkg::cva6_cfg_t` with `cva6_user_cfg_t` + `build_config`, which `cheshire_pkg::gen_cva6_cfg` must follow. That rewrite is exactly what `71f9cb2` contains.

### D2. Config package `cv64a6_imafdchsclic_sv39` (WT), not Cheshire's `_wb`
v2 renames `cv64a6_imafdcsclic_sv39` to `cv64a6_imafdchsclic_sv39`, with the H extension folded into the name. Cheshire's own flow uses the `_wb` variant. Newt overrides `CVA6ConfigDcacheType=config_pkg::WT`, and the plain variant is already WT. The two variants differ only in `DcacheType` and `DcacheFlushOnFence` (0 in plain, 1 in `_wb`). Choosing plain keeps `FlushOnFence=0`, which matches WT semantics and v1 behavior.

`IG_CVA6_PKG_PARAMS` is unchanged. Its sed keys (`localparam … CVA6ConfigX = …`) all exist in the v2 package with the same syntax.

What now changes in the built core, from comparing v1 Cheshire's hardcoded struct with v2's package plus Cheshire's overrides:
- **`RVH` 1 → 0.** This is the intended effect of `CVA6ConfigHExtEn=0`, dead until now.
- **New v2-only fields come from the package defaults:** `RVZiCond=1`, `PerfCounterEn=1`, `MmuPresent=1`, `RvfiTrace=1` (probe ports, unconnected at the SoC), `DataUserEn=0`.
- **Every other field v1 Cheshire set is equal in v2 or still overridden by Cheshire:** commit ports, load buffer, outstanding stores, PMP, Zcb, address and region rules.

`DataUserEn=0` needs a check (task 3.3). v1 had no enable, only `DATA_USER_WIDTH` (newt sets 64). Upstream Cheshire runs v2 with `DataUserEn=0`, so this is expected to be harmless.

### D3. Pin `ZKN = 0` in the fork, not in `iguana.mk`
`ZKN` is not a `localparam CVA6Config*` in v2's packages. It is a literal `ZKN: bit'(0)` inside the struct, so the `IG_CVA6_PKG_PARAMS` sed cannot reach it. Setting it in `gen_cva6_cfg` next to `CvxifEn = 0` makes the value newt-owned and visible.

The Zkn logic needs `ZKN && RVB`, and `RVB` is also 0. The `aes` unit is only generated under `if (CVA6Cfg.ZKN)` in `ex_stage.sv`, so with both off nothing reaches the netlist.

### D4. Lock the fork's tested subtree by hand
This follows Phase 13's policy. Only the entries the cherry-pick moves are changed:
- `cheshire` → the fork commit;
- `cva6` `9338c2c` → `4c02b24`;
- `clic` `8ed76ff` (2.0.0) → `6515a71` (3.0.0);
- `fpnew` `f231041` → `e5aa6a0`.

Those are the revisions in the fork's own `Bender.lock` after the pick. `clic` 3.0.0 asks for `common_cells` ^1.26 and `register_interface` ^0.3.9, both already satisfied (1.38.0 / 0.4.5). Task 2.2 checks the result with `bender sources`.

## Risks / Trade-offs

- **R1 [pickle toolchain rejects new v2 constructs]** → Same playbook as Phase 13: run `ig-hw-all pickle-all`, sweep every rule, and add fork fixes under the `-newt.<N>` tag rather than patch-tree rules (ADR-0002). If svase/sv2v cost too much, sequence this change after `replace-svase-sv2v-with-read-slang` instead.
- **R2 [Metric move reads as a regression]** → Losing the H extension shrinks the core; v2 microarchitecture changes move it either way. Record the before/after from the synth lane, attribute it, and only then reseed the baseline.
- **R3 [The SHA-3 coprocessor diverges further]** → Accepted. Its port is a follow-up, and its thesis PPA numbers can be taken on v1 before merging this change.
- **R4 [A Cheshire `main` release later moves CVA6 differently]** → Rebasing the fork onto that release drops the cherry-pick as a duplicate. No newt-side change is expected.
