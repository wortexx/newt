# Proposal

## Why

CVA6 is pinned to `pulp-v1.0.0` (`9338c2c`, 2024-02-25), reached transitively through the Cheshire fork. The only newer release on the PULP line is **`pulp-v2.0.0`** (`4c02b24`, 2025-07-17): 609 commits, about +17.6k/−12.7k lines in `core/`. Upstream Cheshire moved to it in `71f9cb2` ("treewide: Update CVA6 to `pulp-v2` and add vCLIC support"), which is on `main` but in no release yet.

The bump matters for the thesis for these reasons:

- **CV-X-IF 1.0.** v1 has the pre-1.0 draft interface (`cvxif_pkg::cvxif_req_t`/`cvxif_resp_t`). v2 has the CV-X-IF 1.0 issue/register/commit/result interface (`cvxif_types.svh`). Any coprocessor meant to outlive the thesis should target 1.0.
- **Native Zkn exists in v2.** v2 has native Zkn (AES, SHA-2, Zbk*) behind `cva6_user_cfg_t.ZKN`. That gives a comparison point for the CV-X-IF coprocessor. This change keeps it off.
- **The CVA6 config becomes real.** In v1, Cheshire builds the whole `config_pkg::cva6_cfg_t` in `gen_cva6_cfg` and hardcodes `RVH: 1`, and no v1 package reads `CVA6ConfigHExtEn`. So `iguana.mk`'s `CVA6ConfigHExtEn=0` has had no effect, and the netlist has been carrying the H extension. In v2, Cheshire starts from the selected config package (`cva6_config_pkg::cva6_cfg`) and overrides only SoC fields, so every `IG_CVA6_PKG_PARAMS` entry takes effect.
- **Two CVA6 workarounds go away.**
  - `wt_axi_adapter2.patch`: the negative-width replication `{{CVA6Cfg.AxiAddrWidth-riscv::PLEN{1'b0}}, paddr}` is now `CVA6Cfg.AxiAddrWidth'(paddr)` upstream. The same construct is what currently breaks the Verilator model (`verilator-sim-flow` 3.1 note).
  - The `pickle.mk` `rtl-patches` sed on `ariane_pkg.sv`: its target text (`<< riscv::XLEN-2`) does not exist even in `pulp-v1.0.0`, so it was already dead. ADR-0002 IMP-003 asked for it to go.

The SHA-3 CV-X-IF coprocessor on `sha3-cvxif-coprocessor` targets the v1 interface. Porting it is **out of scope** here (see Impact).

## What Changes

- **Cheshire fork `v0.3.1-newt.2`** on `newt/v0.3.1`, on top of `v0.3.1-newt.1`:
  1. Upstream `71f9cb2`, cherry-picked. It raises `cva6` to `pulp-v2.0.0` and `clic` 2.0.0 → 3.0.0, switches `gen_cva6_cfg` to `cva6_user_cfg_t` built from the config package, and adds vCLIC config fields. Conflicts were resolved to keep the fork's iDMA 0.6.3 pin and nonfree commit; on the Xilinx top only the `USE_VCLIC` block is taken.
  2. `ret.ZKN = 0` next to `ret.CvxifEn = 0` in `gen_cva6_cfg` (design D3).
- **`Bender.yml`**: `cheshire` → `rev: v0.3.1-newt.2`. **`Bender.lock`**: `cheshire`, `cva6` (`4c02b24`), `clic` 3.0.0 (`6515a71`), `fpnew` `pulp-v0.2.3` (`e5aa6a0`), the exact set the fork's own lock was cherry-picked with.
- **`iguana.mk`**: `IG_CVA6_CONFIG` `cv64a6_imafdcsclic_sv39` → `cv64a6_imafdchsclic_sv39`. `IG_CVA6_PKG_PARAMS` is unchanged, but now effective (design D2).
- **Pickle patches**: `patches/morty/wt_axi_adapter2.patch` deleted. The `rtl-patches` macro and its call are removed from `pickle.mk`.
- **CI**: `ci.yml`'s Verilator lint flist uses the new config target.
- **Docs**: `AGENTS.md`, `openspec/config.yaml`, `docs/custom-isa-extension.md` and `docs/infra-plan.md` name the new config and pin.
- **Behavioral (core)**, all expected:
  - H extension removed (`RVH` 1 → 0).
  - fpnew `pulp-v0.1.1` → `pulp-v0.2.3`.
  - CVA6 microarchitecture: 609 commits of upstream change.
  - CLIC 3.0.0, with CLIC still disabled in `CheshireCfg`.

  Area, timing and cell counts will move, and `synth-baseline.json` must be reseeded deliberately.

## Capabilities

### Modified Capabilities

- `rtl-dependencies`: the Cheshire pin requirement moves to `v0.3.1-newt.2`. A new requirement states that the CVA6 configuration the project declares is the one the core is built with, and that ISA extensions the project does not use are pinned off explicitly.

## Impact

- **RTL**: CVA6, CLIC and fpnew revisions. `hw/iguana_*.sv` is unchanged: `iguana_pkg` sets no CVA6 or CLIC fields, and the `cheshire_soc` port list is unchanged by `71f9cb2`.
- **pickle**: svase/sv2v must accept roughly 17k changed lines of CVA6. This is the main unknown, and new patch rules or fork fixes may be needed (design R1). The FMA override (`FMA_CONF := OPT`, `hw/fpnew_fma_opt.sv`) is safe: `src/fpnew_fma.sv` is byte-identical between `pulp-v0.1.1` and `pulp-v0.2.3`.
- **synth**: the keep-hierarchy selectors `fpu_gen`, `gen_asic_regfile.i_ariane_regfile` and `float_regfile_gen` still name instances in v2, and `gen_cva6_cores` must be checked. Expect a metric move, recorded against `synth-baseline.json`.
- **sim**: Questa `ig-sim-rtl` and the Cheshire tests to re-run. Verilator may get past its `wt_axi_adapter` internal error.
- **sw**: none expected. Cheshire `sw/` gains only the CLIC tests.
- **Interacting work**:
  - `sha3-cvxif-coprocessor`: `hw/coproc/keccak_cvxif.sv` and its TB use `cvxif_pkg`, which v2 removes. Its interface port to CV-X-IF 1.0 is a separate follow-up, deliberately not done here.
  - `replace-svase-sv2v-with-read-slang`: one of its three planned fork fixes (the `wt_axi_adapter` replication) is now upstream.
