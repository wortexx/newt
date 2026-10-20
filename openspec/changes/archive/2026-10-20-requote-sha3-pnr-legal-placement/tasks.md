# Tasks

Tags: **[edit]** plain editing, cheap to verify. **[eda]** needs the EDA tools locally (Docker image). **[long-run]** dispatches a synth or P&R lane on the self-hosted VM: ask the user before each dispatch.

## 1. Secure the both-arms side (probe B)

- [x] 1.1 **[edit]** Confirm that probe B is `main`'s flow. Run `git diff 3fdacef <main HEAD> -- hw target/ihp13 Bender.yml Bender.lock scripts/pnr`. Verify the only difference is comment lines (today: 8 in `gpl.tcl`). If anything else differs, stop and ask the user whether probe B still stands (design D1). — done 2026-10-14 against `52978e1`: the only difference is the 8-line routability-inflation comment in `gpl.tcl`.
- [x] 1.2 **[edit]** Download run `38395368038`'s `pnr-reports` to `target/ihp13/openroad/out/ci-38395368038/` (expires 2026-11-12; design D6). Verify:
  - `save/pnr_status.log` shows every stage `ok` through `grt`;
  - `pnr_floorplan.log` has the `Die: 6777.0 x 5950.0 um (core scale 1.10 …)` line;
  - `pnr_dpl.log` and `pnr_cts.log` each contain `Placement legal after`.

  — done: all three hold (`floorplan`…`grt ok`, then `grt stop-after`; die 6777.0 × 5950.0 µm at core scale 1.10; legal after `dpl` and `cts`).

## 2. Build the reference branch

- [x] 2.1 **[edit]** Create branch `pnr-reference-no-arms` from `main` and make the three edits in design D1:
  - `iguana_pkg.sv`: drop `Cva6CvxifEn` and the `AxiExt*` lines;
  - `iguana_soc.sv`: remove the two Keccak instances, tie off `cvxif_resp_i`, and restore the `axi_ext_slv_*` port connections to their `f4d43db` form;
  - `project-synth.mk`: remove the two Keccak keep-hierarchy selectors.

  Add a header comment on each edit saying the branch is a measurement reference that is never merged. Verify with `git diff main --stat`: exactly those three files.

  — done: commit `5314f50` on `pnr-reference-no-arms` (from `52978e1`); `git diff main --stat` shows only `hw/iguana_pkg.sv`, `hw/iguana_soc.sv` and `target/ihp13/yosys/project-synth.mk`. Amended by `fe8e84d` (`Bender.yml`; design D1, after task 3.2's first check failed), so the branch now differs from `main` in four files. `cvxif_req_o` is left open and `cvxif_resp_i` tied to `'0`, as `cheshire_soc.sv` (`newt.2`) documents. The `AxiOutKeccak*` localparams stay, unused.
- [x] 2.2 **[eda]** Verify that the branch elaborates. Run `make ig-hw-all` and a Verilator lint of `iguana_chip` (the fast lane's `lint` command) in the `newt-eda` image: no errors, and no remaining `keccak` reference in the elaborated hierarchy. Push the branch. Expect the fast lane's `sim-soc`/`sw` SHA-3 programs to fail there, since the hardware is gone. That is expected and not a gate for this branch.

  — done, with `make ig-hw-cva6` (what `sim-soc` runs) instead of `ig-hw-all`. On a fresh clone `ig-hw-all` fails in `ig-hw-fma-opt`: `IG_CHS_FMA_DIR` is resolved with `bender path fpnew` when the Makefile is parsed, before any checkout, and comes out as `/src/`. That doesn't depend on this branch; the lanes run it after their dependency step. Local workarounds, none of which change the branch: main's `.bender` and PDK submodule were reused, because anonymous GitHub clones from the container were refused and Docker's bind mount breaks git's local-clone hardlinks. Result: `verilator --lint-only --timing -Wno-fatal -f flist.verilator.f --top-module newt_verilator_top` exits 0 with 0 `%Error`. The only Keccak mentions are 4 `TIMESCALEMOD` warnings on the `hw/coproc` sources, which Bender still lists but nothing instantiates; 3.2 confirms on the netlist. Pushed. The fast lane runs only on PRs and pushes to `main`, so nothing ran on the branch.

## 3. Reference synthesis and netlist check

- [x] 3.1 **[long-run]** *(ask the user first)* Dispatch `synth.yml` on `pnr-reference-no-arms` (`workflow_dispatch`, default image). Download its `synth-reports` to `target/ihp13/yosys/out/ci-<run>/`. Verify: run succeeded, yosys `CHECK` 0 problems.

  — done (approved 2026-10-14). Run `38641205073` (`5314f50`) and, after the D1 amendment, run `38722761290` (`fe8e84d`): both succeeded with `CHECK` 0, and their reports are saved under `target/ihp13/yosys/out/ci-<run>/`.
- [x] 3.2 **[edit]** Compare cells, area and flip-flops with pre-coprocessor run `36447894410` (735,557 cells / 17,771,117 µm² / 89,249 FFs, recorded in `docs/results/sha3-ppa.md` § "SoC synthesis"; design D3). Verify every metric is within ±0.05 %. If not, stop and report the delta to the user before any P&R dispatch.

  — attempt 1 (run `38641205073`, `5314f50`; the VM had to be started by hand because the synth lane does not start it, and the queued nightly `main` cron `38700189762` was cancelled at the user's request): `CHECK` 0, but cells 732,370 (−0.43 %), area 17,752,919 µm² (−0.10 %), flip-flops 89,232 (−0.02 %). All 69 modules have the same parameter hashes. Every kept module matches cell for cell except `axi_llc_reg_wrap` (−292) and `cheshire_idma_wrap` (+187); the rest is the flattened top (−3,082 cells). No Keccak module. Out of band, so it stopped. The user chose to drop the `hw/coproc` sources from the branch's `Bender.yml` and re-synthesize (design D1 amended). Attempt 2: run `38722761290` (`fe8e84d`) is cell-for-cell identical to attempt 1, so the `hw/coproc` sources were not the cause.
  - Same Yosys (`143eb14f9`) and ABC build in all four runs.
  - Kept modules drift run to run even when their RTL is unchanged (`axi_llc_reg_wrap` moves ±0.03 % between the CV-X-IF-only and both-arms runs).
  - `cva6` equals the old reference exactly (6,760,001 µm²).
  - The remaining −18,198 µm² is in the flattened top, and goes with the only other RTL difference: Cheshire `newt.2` against `newt.1`.

  **Decision (user, 2026-10-15):** proceed to P&R and state the deviation. The new reference shares Cheshire `newt.2` with probe B, so it is the closer like-for-like reference. Design D3's band becomes "report the deviation", which the spec's scenario already allows. The report carries cells −0.43 %, area −0.10 %, flip-flops −0.02 %, where the delta sits, and that it follows the Cheshire pin.

## 4. Reference place and route

- [x] 4.1 **[long-run]** *(approved 2026-10-14, conditional on 3.2; dispatched as run `38772313345` after the user's 2026-10-15 decision)* Dispatch `pnr.yml` on `pnr-reference-no-arms` with `stop_after=grt` and every other input empty (design D2). Download its `pnr-reports` to `target/ihp13/openroad/out/ci-<run>/`. Verify the same three points as task 1.2 for this run, and that the `Die:` line equals probe B's. If a gated stage fails, record the stage and log and stop for the user's decision. Do not quote a partial run.

  — done. Run `38772313345` (`fe8e84d`) succeeded on every job (`start`, `restore-checkpoints`, `pnr`, `upload-checkpoints`, `stop`):
  - `floorplan` … `grt ok`, then `grt stop-after`;
  - `Die: 6777.0 x 5950.0 um (core scale 1.10 …)`, identical to probe B's;
  - legal after `dpl` and `cts`.

  `gh run download` stalled on the 102 MB artifact (mostly `basilisk_route.guide`), so it was fetched as the API zip with `curl -C -` resumes over a slow link. It is saved in `target/ihp13/openroad/out/ci-38772313345/`.

## 5. Generator

- [x] 5.1 **[edit]** Make `scripts/sha3_ppa.py` parse the `Die:` line, the `Placement legal after dpl|cts` lines, and the uniform-activity total power from `basilisk.grt.rpt` (design D4). Make it refuse to emit the P&R table on a missing legality line, on overlaps, or on mismatched dies, with an error naming the run and the item. Verify:
  - on the two downloaded artifacts it generates without error;
  - pointing `--pnr-ref` at a copy of the reference reports with the `Placement legal after cts` line removed fails with a message naming that run and `cts`;
  - a copy with a different `Die:` line fails naming the die mismatch.

  — done. New helpers `pnr_placement_facts` (die, legalizer, legal stages), `pnr_uniform_power`, `pnr_run_problems` and `pnr_comparable`; `main` exits with every problem listed. The unused `pnr_legalized_cells`/`cts_cells` went. Verified before the reference run existed, so probe B stood in for both sides; the real pair is re-run in 6.1:
  - probe B against itself: generates, rc 0;
  - `Placement legal after cts` removed from the reference copy: `run MUT1 (reference): no 'Placement legal after cts'`, rc 1;
  - die line changed to 1.00: `die mismatch: run 38395368038 '6777.0 x 5950.0 um (core scale 1.10 …)' against run MUT2 '6230.0 x 5478.0 um (core scale 1.00 …)'`, rc 1.
- [x] 5.2 **[edit]** Make the P&R section's text come from the parsed data (design D4):
  - the flow sentence (die size and scale, diamond legalizer, legal after `dpl`/`cts`, `stop_after=grt`);
  - the SoC power paragraph (both runs' uniform-activity totals and delta, comparative only; one sentence on default activity, Phase 17; the hard-coded +14.6 % / +6.1 % and the coprocessor-only figure removed);
  - the conditional "WNS barely moves" and "congestion fell" sentences;
  - removal of the "Placement was not legal" paragraph.

  Verify by reading the generated section: every number in it can be traced to one of the two artifacts.

  — done (`pnr_period_text`, `pnr_power_text`, `pnr_caveat_text`; `PNR_WNS_SAME_NS` = 0.5 ns). The self-comparison's section was read through: every figure is from probe B's reports (die, legalizer, WNS/TNS, demand, wirelength, `DPL-0009`, HPWL, 1.06 W), and the achieved period comes out at 19.96 ns.

## 6. Results docs

- [x] 6.1 **[edit]** Regenerate `docs/results/sha3-ppa.md` with `--pnr <probe B dir> --pnr-run-id 38395368038 --pnr-ref <reference dir> --pnr-ref-run-id <run>`. Keep every other input the current page was generated with (block, SoC synth, power, MMIO; recover them from the generator's docstring and the page's own citations). Verify with `git diff`: only the P&R section changes, plus the achieved-period column and the text in the energy sections. Every other section is byte-identical.

  — done. The inputs are the page's own runs (`--soc 37005575294 --soc-ref 36447894410 --soc-both 37218328058`, all saved under `target/ihp13/yosys/out/`) plus the new pair. The diff touches only the P&R section, the achieved-period column (19.23 → 19.96 ns; energy per byte moves ≤ 0.1 pJ/B, only leakage scales) and the energy section's period sentence.

  **Found here, user decision 2026-10-16:** uniform-activity SoC power came out 1.25 W for the reference and 1.06 W with both arms (−15.2 %). The whole inversion is the clock network: 0.611 against 0.397 W, with CTS inserting 20,842 against 15,180 clock buffers. On the shared die, the smaller reference is placed more sparsely (`DPL-0009` 50.4 % against 56.3 %). The user chose to split the paragraph: totals, clock network, and everything else, the last summed from the groups (+5.2 %), with only the non-clock delta attributed to the arms. The caveat now names the sparser placement instead of saying "congestion fell although the netlist grew". This extends design D4.
- [x] 6.2 **[edit]** Update `docs/results/sha3-evaluation.md` (design D5):
  - the timing table row and its prose, with the new WNS pair, run IDs, die and legality;
  - the achieved period, everywhere it appears (today 19.23 ns, in about 14 places across `docs/results/*.md`; `grep -n '19.23\|8.23'`);
  - the energy figures at that period, copied from the regenerated page;
  - the "placements were not legal" paragraph replaced by a dated "Superseded" note with the old pair (`37108127061` / `37162759719`, −8.36 / −8.23 ns, 19.23 ns), the reason, and the before→after.

  Verify: `grep -n '19.23\|8.23\|37162759719\|37108127061' docs/results/` hits only the superseded note.

  — done; the grep hits only the superseded note.
  - Timing: the new pair, legality, die and reference-netlist deviation.
  - **Found 2026-10-16: with both arms, the worst `grt` path is inside `i_keccak_cvxif`'s R = 6 round logic** (`state_i_26` → `state_i_541`, −8.96 ns; the reference's is in CVA6's D-cache, −8.39 ns). The user chose to report it and leave R-at-P&R as follow-up. The R-sweep paragraph now says the block-level rule did not survive placement, and the generator names each run's worst path and flags SHA-3 instances (`pnr_worst_path`, `sha3_instance`), replacing the 0.5 ns WNS heuristic.
  - Energy at 19.96 ns.
  - The uniform-activity power paragraph with the clock split.
  - A "No signoff layout" limitation and a spec-coverage row.
- [x] 6.3 **[edit]** In `docs/infra-plan.md`:
  - tick Phase 11's "Requote the thesis P&R figures" item with the two run IDs and the new WNS pair;
  - update the §0 "Basilisk WNS" row's resolution sentence to the new figures.

  Verify the item reads `- [x]` and that both run IDs appear.

  — done. Phase 11's requote item is ticked with both run IDs, and the §0 row carries the requote. Two follow-ups are added: choosing R from placed timing, and the DRC-clean P&R the user set as the next goal (2026-10-16), with these figures parked as the safety net.

## 7. Integration check

- [x] 7.1 **[edit]** Run `openspec validate requote-sha3-pnr-legal-placement --strict`. Run the fast lane on the PR for `main` (`lint`, `sw`, `sim-unit`, `synth-coproc`, `sim-soc`); they are unaffected and must stay green. Verify that the PR's diff touches only `scripts/sha3_ppa.py`, `docs/results/*.md`, `docs/infra-plan.md` and this change's directory. The `pnr-reference-no-arms` branch is not part of the PR and stays unmerged. **Done 2026-10-20 (PR #79):** the change validates, all five fast-lane checks passed, and `pnr-reference-no-arms` stays unmerged (fe8e84d). By user decision, the PR was one combined progress PR. Besides this change's files it also carried `docs/figures/coproc/*` (the coprocessor diagrams), `openspec/changes/drc-clean-pnr/tasks.md` and the `replace-svase-sv2v-with-read-slang` proposal. None of them touches the flow, RTL or workflows. The user accepted that.
