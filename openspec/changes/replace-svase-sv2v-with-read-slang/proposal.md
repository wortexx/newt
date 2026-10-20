# Replace svase + sv2v with yosys's built-in slang frontend

## Why

The synthesis frontend runs two tools whose only job is to make SystemVerilog readable by a yosys that could not read it. `svase` (pre-elaborate) is **archived upstream** — no fix will ever land again — and `sv2v` (downgrade to Verilog) is a second lossy translation hop behind it. Both were unavoidable while yosys had no SystemVerilog frontend. That is no longer true: `upgrade-yosys-upstream` put the flow on upstream v0.69, which ships the slang frontend (`read_slang`) built in, and Phase 8 of `docs/infra-plan.md` has been waiting on exactly that.

A spike on 202  r mg6-09-18 (OSS CAD Suite yosys 0.69+73, arm64, local) settled the open question: `read_slang` elaborates the complete `iguana_chip` design to a word-level netlist with **zero errors in 5.3 s using 1.4 GB**, against a three-tool chain that takes minutes and emits a ~180 MB intermediate file nobody can diff. The spike also showed the current patch set is mostly obsolete — of eleven pickle-stage patches, three are genuinely needed and the rest address constructs slang handles natively.

The secondary motive is that this retires *patching generated text* as a mechanism. The project's own convention is to fix dependencies through Bender-pinned forks, not `sed` scripts against a 180 MB pickle, and the three surviving fixes are real RTL bugs that belong in forks.

## What Changes

- **BREAKING** — The pickle stage stops producing `basilisk.sv2v.v`. Yosys reads the Bender file list through `read_slang` directly; `svase` and `sv2v` leave the synthesis path entirely. Morty is not required for elaboration (the spike ran without it); whether it survives for the source snapshot is a design decision.
- Technology cells, SRAM macros, IO pads and the delay line are made known to the frontend as blackboxes via `read_liberty -lib` calls placed **before** `read_slang`. The frontend has retired `--ignore-unknown-modules`, so this is the supported route.
- Three design fixes move out of pickle-stage patches and into Bender-pinned forks: a negative-width replication in CVA6's `wt_axi_adapter`, a malformed assignment pattern in `cheshire_pkg`, and a non-`if`/`else` asynchronous-reset flop in `serial_link_physical`.
- The `sv2v` sed script's reset-address override is a **design change disguised as a tool workaround** and gets an explicit home. Nothing will error if it is silently dropped, which is precisely the risk.
- The synthesis script gains frontend options (`--keep-hierarchy`, `--allow-use-before-declare`, `--relax-enum-conversions`, `-D COMMON_CELLS_ASSERTS_OFF`) and a `chformal -remove` step: unguarded concurrent assertions lower to `$check` cells that set a `keep` attribute propagating to the top module, which would otherwise block the flow's `flatten`.
- Backend scripts are updated for the netlist naming contract. Slang emits LRM generate-block names (`gen_cva6_cores[0]`) where sv2v emitted `gen_cva6_cores.__0`. One of 32 keep-hierarchy selections is affected; the OpenROAD macro-placement scripts carry 25 to 37 such paths each.
- Backend instance lookups gain non-empty assertions. A `get_cells` glob matching nothing is not a Tcl error, so a naming mismatch degrades placement or drops constraints in silence — the failure mode that already leaves worst-slack unavailable today.
- **BREAKING** — `svase` and `sv2v` (and the Haskell toolchain built solely for `sv2v`) are removed from the `newt-eda` image and its smoke test.
- **BREAKING** — The `ig-sim-sv2v` Questa target and the `sv2v` Bender target are removed; their input no longer exists.
- `README.md`, `AGENTS.md` and `openspec/config.yaml` are updated to describe the new flow shape.

## Capabilities

### New Capabilities

- `synth-flow`: What the frontend-to-netlist half of the flow must guarantee — which tool elaborates the RTL, how non-RTL cells are made known to it, where design fixes are allowed to live, what the emitted netlist's hierarchical naming contract is (the backend depends on it by literal string), and that formal properties never reach technology mapping. The backend-side sibling, `pnr-flow`, already exists; this is the missing frontend half.

### Modified Capabilities

- `eda-tooling-image`: "Image toolchain contents" currently mandates `svase f5f5290` and `sv2v v0.0.11` on `PATH` and asserts them in the smoke test. Both requirements and their scenario drop.
- `ci-pipeline`: "Synth lane runs the full pickle-to-netlist flow" names `pickle-all` as a distinct stage producing a pickled file. The stage's shape and contract change.

> **Note from `bump-cheshire-v0-3-1`.** Cheshire moved from `4a270af` to `v0.3.1` there. Three consequences for this change:
> - **Fork base.** Any Cheshire fork cut here should branch from `v0.3.1`.
> - **The `cheshire_pkg` fix may be moot.** The "malformed assignment pattern in `cheshire_pkg`" is presumably the CVA6 ID-map `'{default: '{0, 0}}`. v0.3.1 rewrote it as `'{default: DefaultMapEntry}`, and the morty sed rule for it was deleted there because svase, sv2v and yosys `read_verilog` accept the new form. Re-run the `read_slang` spike on v0.3.1 before forking for it.
> - **The patch set shrank and the apb_uart hold can be revisited.**
>   - Removed: `wt_axi_adapter.patch` (dead), `protocol_e_axi_renaming.patch`, the ID-map sed rule, and the dead `i < advance` sv2v rule.
>   - `apb_uart` is held at 0.2.1 only because yosys's Verilog frontend rejects 0.2.3's OBI UART loop. Slang should accept it, so revisit the hold here.

## Impact

**Flow stages touched**: RTL (fork fixes), synth (frontend replacement — the core of the change), backend (naming contract and lookup assertions), sim (loses the post-sv2v Questa target), CI (synth lane), and the tooling image. Software is untouched.

**Code**: `target/ihp13/pickle/pickle.mk` and its `patches/` tree, `target/ihp13/yosys/yosys.mk` and `scripts/yosys_synthesis.tcl`, `target/ihp13/openroad/scripts/macros*.tcl` and `src/basilisk_instances.sdc`, `iguana.mk`, `tools.mk`, `Bender.yml`, `docker/pickle/Dockerfile`, `docker/smoke-test.sh`, `.github/workflows/synth.yml`.

**Dependencies**: new Bender-pinned forks of `cva6`, `cheshire` and `serial_link` carrying the three fixes.

**Known risks carried into design**:
- `--keep-hierarchy` is what makes the flow's selective keep-hierarchy selections resolvable, and upstream marks it experimental. It did not crash on this design, but the label is real.
- Synthesis quality of results is unmeasured. The frontend swap is a full re-elaboration, so cell count, area and DFF count must be gated against `synth-baseline.json` (reseeded at v0.69 adoption) before this is adopted, exactly as the yosys upgrade was.
- Removing `ig-sim-sv2v` removes the only functional check on the frontend's output. Either gate-level simulation of the synthesized netlist covers it, or the gap is accepted explicitly.
