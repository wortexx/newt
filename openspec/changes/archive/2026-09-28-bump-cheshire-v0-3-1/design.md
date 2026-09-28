# Design

## Context

The pinned Cheshire commit (`4a270af`) and `v0.3.1` were compared directly (shallow fetches of both, then `git diff`). Only these facts bear on the approach:

- **`hw/` delta.** Only four things change in `hw/`:
  - `cheshire_pkg.sv`: address-map constant `AmSpmUnc`, debug `HaltAddress`/`ExceptionAddress` made relative to `DmBaseAddress` (`0x800`/`0x810`), the ID-map default, the VGA default (RGB565), and 64-bit literals.
  - `cheshire_soc.sv`: the parenthesization fix in the SPM remap, and the DMA instance `dma_core_wrap i_dma` → `cheshire_idma_wrap i_idma`. The `gen_dma` generate label is unchanged.
  - `cheshire_idma_wrap.sv`: new file.
  - bootrom (`.S`/`.c`/generated `.sv`).

  `cheshire_reg_pkg`/`reg_top` are untouched, so the svase `RegOut.num_out → 8'd14` rule stays valid. The `cheshire_soc` port list is identical.
- **What the project touches.**
  - `iguana_pkg` builds `CheshireCfg` from `DefaultCfg` with explicit overrides. Its VGA override (5/6/5) already equals the new default, so `CheshireCfg` is unchanged apart from the non-overridden fields listed above.
  - `iguana_soc` uses only the `cheshire_soc` ports and `cheshire_cfg_t` fields, all of which are present in both revisions.
- **Flow artifacts keyed on dependency text.**
  - `project-synth.mk` keeps `*/gen_dma.i_dma`.
  - `morty.sed` rewrites `default: return '{default: '{0, 0}};`, text that no longer exists in v0.3.1.
  - The line-number-anchored patches under `patches/{morty,svase}` are applied with `-patch`, so failures are ignored.
- **Transitive deps.** Cheshire v0.3.1 raises axi, register_interface, common_cells, common_verification, iDMA, apb_uart and axi_rt, and adds dram_rtl_sim. The CVA6 pin is `pulp-v1.0.0` in both revisions. The current lock already resolves across mismatched 0.x minors (hyperbus asks for register_interface 0.3.2, and the lock has 0.4.4), so root precedence is how conflicts get settled.

## Goals / Non-Goals

**Goals:**
- Land on upstream `v0.3.1` without modifying Cheshire or CVA6 and without changing `hw/iguana_*.sv`.
- Make every silent-failure point visible: selectors, sed rules, and ignored patch hunks.
- Leave `main` in a state where the next Cheshire fork (read_slang fixes, CV-X-IF) branches from a tag.

**Non-Goals:**
- Fixing the Verilator 3.1 debug-module blocker. A re-test is recorded; a fix is not promised.
- Retiring the pickle toolchain (that is `replace-svase-sv2v-with-read-slang`).
- Adopting any new Cheshire v0.3.1 features (config fields, new sim scripts, Xilinx targets).
- Re-closing timing, or any backend run.

## Decisions

### D1: Declare `version: 0.3.1`, not `rev: v0.3.1` or `rev: 5c76406…`
This matches how every other dependency in `Bender.yml` is declared and satisfies the spec's "released tag" requirement. Exactness comes from `Bender.lock`, which is how the rest of the graph works too.
*Alternative*: `rev: 5c76406…`. It is more explicit, but it loses the semantic-version signal, and a `bender update` would never propose v0.3.x patch releases.

### D2: Lock Cheshire's subtree to Cheshire v0.3.1's own tested lock
*(Revised during apply. The original plan was `bender update cheshire`, which the image's bender 0.27.4 does not support.)*

`Bender.lock` takes, for every package Cheshire v0.3.1 itself locks, the exact revision from Cheshire's upstream `Bender.lock`. Our `hyperbus` entry and the new `cheshire` entry are added to that. The root pins in `Bender.yml` (`axi 0.39.6`, `register_interface 0.4.5`) equal those tested versions. Two consequences follow:
- Synth and sim drift is attributable to one released, upstream-CI'd combination.
- CVA6 and fpnew revisions are provably unchanged.

The lock is merged by hand and validated by `bender sources` under both 0.27.4 (image/CI) and 0.32.0. 0.27.4 leaves it byte-identical.

*Alternatives:*
- `bender update cheshire --recursive` (0.32.0). Tool-generated, but it floats 12 packages to newer patch releases that no upstream release tested together (axi 0.39.11, iDMA 0.6.5, common_cells 1.40.0, …).
- A full `bender update`. Same drift, plus unrelated packages.

*Caveat*: a later blanket `bender update` will float these forward. The existing `register_interface` (hyperbus `^0.3.2`) and `axi` (cva6 `^0.31`, serial_link/irq_router `^0.38`) conflicts require interactive resolution to the root requirement, as they already did for the previous lock.

### D3: Verify selectors and patches against the pickle, not against a synth run
Keep-hierarchy selectors and sed/patch rules can all be checked against the morty/svase pickle output, which takes minutes, so full Yosys synthesis (~2.5 h) is not needed:
- Grep the pickle for each selector's instance path.
- Run each sed rule with `sed -n '/pattern/p'`.
- Run each patch with `patch --dry-run`, and treat any rejected hunk as a finding.

The full synth lane run is the final, non-blocking confirmation (label `full-synth` on the PR), and its metric drift gets recorded.
*Alternative*: rely on a green synth lane. Rejected. The synth lane passing is exactly what a silently-unmatched selector or rule does *not* prevent.

### D4: Rule for the ID-map sed rule — re-target only if the tools still choke
The old rule exists because the original `'{default: '{0, 0}}` nested pattern was not accepted downstream. v0.3.1 replaced it with `'{default: DefaultMapEntry}`, where `DefaultMapEntry` is a local `int unsigned [2]`.
- If morty → svase → sv2v accept the new form, delete the rule.
- If they reject it, re-target the rule at the new line, keeping the same `cva6_id_map_t'{default: '0}` replacement.

The observable result is the same either way, because both forms produce all-zero entries.

*Outcome (apply)*: the rule is deleted. The pickle completes without it, and the Yosys front-end replay (`read_verilog -sv` + `hierarchy -check`) accepts the result.

### D6: Hold apb_uart at 0.2.1 (added during apply)
Cheshire v0.3.1's tested set uses apb_uart 0.2.3. That version replaces the silicon-proven slib-based UART with an OBI UART from the new `obi_peripherals` package. Its `obi_uart_tx` contains `for (i = 0; i <= word_len_bits; …)`, a loop bounded by a signal, which Yosys's Verilog frontend rejects: `ERROR: 2nd expression of procedural for-loop is not constant!`.

That loop is the only Yosys blocker. With it rewritten in a scratch copy of the netlist, the whole design reads and passes `hierarchy -check`. The project therefore pins `apb_uart: 0.2.1` at the root, with a comment giving the reason, and locks the 0.2.1 entry, so `obi_peripherals` drops out of the lock.

This hold is safe because `reg_uart_wrap`'s interface is identical in 0.2.1 and 0.2.3, and Cheshire's instantiation of it is unchanged between the old pin and v0.3.1. The UART RTL is exactly what the flow synthesizes today.

*Alternatives:*
- Fork `obi_peripherals` with a constant-bound loop. This takes on new, unverified UART RTL and a fork to maintain.
- Add a pickle-stage patch. This goes against the forks-not-patches convention and grows a patch set being retired.

*Revisit* when `replace-svase-sv2v-with-read-slang` lands, since slang elaborates the loop.

### D7: Delete dependency-keyed rules that were already dead (added during apply)
The sweep found three rules that matched nothing on `main` before this change, so deleting them is output-neutral:
- `wt_axi_adapter.patch`, superseded by `wt_axi_adapter2.patch`.
- `sv2v.sed`'s `i < advance` rule, whose loop form never matched.
- The `*/gen_clic.i_clic` keep-hierarchy selector. CLIC is disabled (`Clic: 0`), so there is no `gen_clic` block.

They are deleted so that the `rtl-dependencies` requirements hold as written. The user decided this during apply.

The `gen_clic` case also exposes a stale comment: `iguana_pkg`'s "and activated CLIC" is not what `gen_cheshire_cfg()` does. That is recorded as a follow-up, not changed here. Enabling CLIC is a design change, relevant to the CV-X-IF/interrupt work, and should re-add the selector.

### D8: CI lint elaborates from the linted file's own modules (added during apply)
`ci.yml`'s per-file `verilator --lint-only` passes every bender file that declares a `package`, so that `import`s resolve. iDMA 0.6's generated `idma_generated.sv` declares packages *and* about 50 modules with `REG_BUS` interface ports. With no `--top-module`, each of those modules becomes a lint root, and every `hw/*.sv` lint failed with 5 %Errors (`Cannot find … interface: 'REG_BUS'`).

The first fix tried was passing interface files as well. It resolves `REG_BUS` but then trips Verilator UNSUPPORTED errors in those unused modules, 51 %Errors per file, so it was rejected.

The step now runs once per module declared in the linted file, each as `--top-module`. A package-only file gets a throwaway `lint_wrap_top` that imports its packages.

Verification ran the real step body, extracted from `ci.yml`, on both `main` and the bump tree:
- 0 %Errors for every module of `iguana_pkg`, `iguana_soc`, `iguana_chip` and `fused_muladd` (6 modules).
- Own-file diagnostics unchanged within ±1, the dropped one being multi-top noise.
- A planted syntax error still fails the step.

The package-file heuristic itself is unchanged.

### D5: Sequence this before `replace-svase-sv2v-with-read-slang` applies
That change will fork Cheshire for a `cheshire_pkg` fix. Doing this bump first means that fork is cut from `v0.3.1`, and D4 may show the fix is already upstream. Its proposal needs a short note once this lands. This change does not edit it.

## Risks / Trade-offs

- **[iDMA 0.5.1 → 0.6.3 changes DMA RTL materially]** → The wrapper is upstream's and is instantiated inside `cheshire_soc`. The software DMA tests in Cheshire's `sw/` are rebuilt, and Questa `ig-sim-rtl` runs a DMA-using test if one is available. Area drift from the DMA is expected and gets recorded.
- **[Bootrom behavior change]** → The bootrom is regenerated by `ig-hw-bootrom-split` from Cheshire's new `.bin`, and the passive-preload (JTAG/SPM) path the sims use is exercised by the green-light test. The `BOOTROM_NUM_PARTS` split must still fit, so check that the generated part count and size are unchanged or explained.
- **[`vip_cheshire_soc` changed (+193 lines) under the Questa fixture]** → Run `ig-sim-rtl` with `helloworld.spm.elf`. If `fixture_iguana`'s instantiation parameters changed, adapt the fixture. That fixture is project code, so the edit is allowed.
- **[Silent patch drift beyond the ones identified]** → D3's dry-run sweep covers *every* rule, not just the two known ones.
- **[Synth metrics move and look like a regression]** → Expected sources: iDMA, the extra CVA6 execute-region rule, and the SPM remap logic becoming live. Record before/after and the cause in `docs/infra-plan.md`. Reseed `synth-baseline.json` only as a deliberate step with that rationale.
- **[CI `bender sources` flakiness masks a real resolution error]** → The existing retry wrapper re-runs with a clean `.bender/`. A deterministic failure still fails after retries.

## Migration Plan

This is a single PR. To roll back, revert it: the lock and pins return together. No generated artifacts are committed (`hw/cheshire_bootrom_split.sv` and `.bender/` are gitignored), so contributors run `make ig-hw-all` after pulling.
