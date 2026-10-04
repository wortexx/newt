# Tasks

Legend: **[edit]** plain editing · **[eda]** needs the `newt-eda` tools (minutes) · **[long]** synth-scale run (hours, non-blocking)

## 1. Capture the "before" reference

- [ ] 1.1 **[eda]** On `main` before any edit, run `make ig-hw-all pickle-all` and keep the morty/svase/sv2v pickles in the scratch area. Also grep the svase pickle for the hypervisor state (`RVH` in the elaborated CVA6 config, or `hgatp`/`vsstatus` CSR logic) to confirm design D2's finding that v1 builds the H extension despite `CVA6ConfigHExtEn=0`.

## 2. Fork and pins

- [x] 2.1 **[edit]** In the Cheshire fork, on `newt/v0.3.1` at `v0.3.1-newt.1`, cherry-pick upstream `71f9cb2` and resolve its conflicts per design D1. Then add `ret.ZKN = 0` per D3.
      Done locally as `71c5bcb` + `e6b9c0d` (not yet pushed; the session had no push access to `wortexx/cheshire`).
- [ ] 2.2 **[edit]** Push `newt/v0.3.1` and create the annotated tag `v0.3.1-newt.2` on `e6b9c0d`, with a message listing both commits. Verify: `git ls-remote https://github.com/wortexx/cheshire.git refs/tags/v0.3.1-newt.2^{}` prints `e6b9c0dace17b679d24e31a98dc1fb781776b055`.
- [x] 2.3 **[edit]** `Bender.yml`: `cheshire` → `rev: v0.3.1-newt.2`, with the comment extended. `Bender.lock`: move `cheshire`, `cva6`, `clic` and `fpnew` per design D4.
- [ ] 2.4 **[eda]** `bender sources -t rtl -t asic -t ihp13 -t cva6 -t cv64a6_imafdchsclic_sv39` exits 0 under the image's bender, and the lock is byte-identical afterwards. Verify that `core/include/cv64a6_imafdchsclic_sv39_config_pkg.sv` is in the list and no `cvxif_pkg.sv` is.
      Pre-checked with host bender 0.32.1, with the fork URL pointed at a local repo holding `e6b9c0d`. `bender checkout` re-resolved and left the lock byte-identical. `bender sources` exited 0 with 603 files: the new config package is present, `cvxif_pkg.sv` is absent, `aes.sv` is absent (not in CVA6's `Bender.yml`; see design D3), and `wt_axi_adapter.sv` has no `AxiAddrWidth-riscv::PLEN` replication left. Caveat: the sandbox could not fetch Cheshire's `sw/deps/cva6-sdk/buildroot` submodule (`git://`), which is unrelated to this change. Still to repeat with the image's bender 0.27.4 against the pushed tag.

## 3. Config and flow rules

- [x] 3.1 **[edit]** `iguana.mk`: `IG_CVA6_CONFIG` → `cv64a6_imafdchsclic_sv39` (design D2). `ci.yml` Verilator flist target updated to match.
- [x] 3.2 **[edit]** Delete `patches/morty/wt_axi_adapter2.patch`; its target text is gone in `pulp-v2.0.0`. Remove the `rtl-patches` macro from `pickle.mk`; its target was already absent in `pulp-v1.0.0`.
- [ ] 3.3 **[eda]** `make ig-hw-all`: confirm `ig-hw-cva6` rewrites every `IG_CVA6_PKG_PARAMS` key in the new package (`diff` the `.orig` against the result: 8 lines changed, `HExtEn` 1→0 and `DcacheType` already WT). Check `DataUserEn=0` against Cheshire's AXI user usage (design D2).
- [ ] 3.4 **[eda]** `make pickle-all`. Sweep every morty/svase/sv2v sed rule and patch against its stage (each rule matches ≥ 1 line, each patch applies with no rejected hunk). Confirm morty accepts the `aes` instance in `ex_stage.sv`'s unelaborated `aes_gen` branch (design D3). For any new svase/sv2v failure on v2 code, record it and fix it as a fork commit, not a patch-tree rule (ADR-0002); see design R1.
- [ ] 3.5 **[eda]** Replay `yosys_synthesis.tcl` up to `hierarchy -check -top iguana_chip` on the final pickle (Phase 13's quick check). Every `YOSYS_KEEP_HIER_INST` selector matches ≥ 1 instance, especially `gen_cva6_cores.__0.i_core_cva6`, `fpu_gen.fpu_i`, `gen_asic_regfile.i_ariane_regfile` and `float_regfile_gen*i_ariane_fp_regfile`.

## 4. Validate

- [ ] 4.1 **[eda]** `make ig-sw-all ig-sim-rtl` with the standard Cheshire test binaries: no regressions against the 1.1 reference run.
- [ ] 4.2 **[eda]** Re-try `make ig-sim-verilator`. Record whether the `wt_axi_adapter.sv:139` internal error is gone in the `verilator-sim-flow` 3.1 note.
- [ ] 4.3 **[long]** Synth lane on the PR. Record cell count, area and runtime before/after in `docs/infra-plan.md`, attributing the H-extension removal separately where possible. Reseed `synth-baseline.json` only as a deliberate step with that rationale.

## 5. Docs

- [x] 5.1 **[edit]** `AGENTS.md`, `openspec/config.yaml`, `docs/custom-isa-extension.md`: new config name and CVA6 version. `docs/infra-plan.md`: Phase 14 entry for this change.
- [ ] 5.2 **[edit]** After merge, open a follow-up for porting `hw/coproc/keccak_cvxif.sv` (branch `sha3-cvxif-coprocessor`) from `cvxif_pkg` to CV-X-IF 1.0 (`cvxif_types.svh`).
