# Use the diamond legalizer (change `use-diamond-legalizer`) — tasks

Tags:

- **[edit]**: plain file editing, checked locally (`tclsh` parse of the stage scripts, `bash -n`,
  `shellcheck`, the driver's `PNR_DRY_RUN=1` mode, `actionlint`).
- **[eda]**: needs OpenROAD from the `newt-eda` image, run locally in minutes.
- **[long-run]**: a P&R lane run on the self-hosted Azure VM (hours). Each one is dispatched
  **only after the user approves it**, never as a speculative check.

## 1. Legalizer selection (design D1, D2, D4)

- [x] 1.1 **[edit]** In `scripts/pnr/common.tcl`, define `pnr_dpl_legalizer`:
  - Read it from `PNR_DPL_LEGALIZER`; an empty or unset value means `diamond`.
  - Reject any value other than `diamond` or `negotiation` with a Tcl `error` naming the
    accepted values.
  - Add `pnr_detailed_placement {args}`. It logs `Legalizer: <name>` via `utl::report`, adds
    `-use_diamond_legalizer` for `diamond`, and calls `detailed_placement`.
  - Comment it in the file's existing style, citing this change and Phase 11.

  Verify: the tclsh parse check that `common.tcl` already supports passes.
- [x] 1.2 **[edit]** Replace the six bare `detailed_placement` calls with `pnr_detailed_placement`:
  `dpl.tcl` (keeping `{*}$DPL_ARGS`), both calls in `cts.tcl`, and the three in
  `grt_repair.tcl`. Verify: `grep -n 'detailed_placement' target/ihp13/openroad/scripts/pnr/*.tcl`
  shows no bare call outside `common.tcl`.
- [x] 1.3 **[eda]** Check the wrapper against the pinned OpenROAD build. In
  `ghcr.io/wortexx/newt-eda:dev`, source `common.tcl`'s legalizer section in `openroad -no_init`
  with `PNR_DPL_LEGALIZER` set to `diamond`, `negotiation` and `bogus`. Verify:
  - the first two build the expected argument list (`-use_diamond_legalizer` present or absent);
  - `bogus` raises the error;
  - `help detailed_placement` still lists `-use_diamond_legalizer`.
- [x] 1.4 **[edit]** Document `PNR_DPL_LEGALIZER` in `run_pnr.sh`'s header next to
  `PNR_GPL_KEEP_RESIZE` and `PNR_DIE_SCALE`. Verify: `bash -n run_pnr.sh`.

## 2. Gated legality check (design D3, D6)

- [x] 2.1 **[edit]** Add `pnr_check_placement {stage}` to `common.tcl`:
  - Run `check_placement -verbose -report_file_name ${report_dir}/${proj_name}_${stage}_check_placement.rpt`.
  - If it fails, read the per-category violation counts from the report's JSON
    (`DPL.category.<name>.violations`) and raise an error naming the stage, each non-zero
    category with its count, and the report path.

  Verify: tclsh parse. The JSON reading is tested against this run's
  `basilisk_cts_check_placement.rpt` (in the `pnr-reports` artifact of run `37996272102`). The
  message must read `Overlap_failures 9718, Padding_failures 9717, Blocked_layers_failures 63`.
- [x] 2.2 **[edit]** In `dpl.tcl`, call `pnr_check_placement dpl` after `optimize_mirroring` and
  before `save_checkpoint`. Verify: by reading the code, a failed check reaches the stage's
  `catch`, so `pnr_status dpl failed …` is recorded and no `dpl` checkpoint is saved.
- [x] 2.3 **[edit]** In `cts.tcl`, replace the caught `check_placement` block (lines 63–81 and
  its comment) with `pnr_check_placement cts`. Keep the report file name it already uses
  (`basilisk_cts_check_placement.rpt`), so the lane's report upload is unchanged. Verify: the
  old "non-fatal" comment and `catch` are gone.
- [x] 2.4 **[edit]** Check that `STAGE_RETRIES` leaves `dpl` and `cts` at 0 (design D6), and
  that `run_pnr.sh` treats a `dpl`/`cts` failure as a gated failure: later stages are reported
  `skipped predecessor-failed` and the exit is non-zero. Verify: `PNR_DRY_RUN=1` shows the stage
  plan unchanged. A short read of the gate logic confirms the exit behaviour; no code change is
  expected there.
  — done. `STAGE_RETRIES` has `dpl`/`cts` at 0; the `newt-eda` dry run prints the same plan
  before and after this change. Correction to the wording above: a gated failure `break`s the
  loop with `overall_rc=1`, so later stages are not run and get no status line at all
  (`skipped predecessor-failed` is only for best-effort stages after the gate). The run still
  exits non-zero without starting `grt`, which is what the `pnr-flow` delta requires.
- [x] 2.5 **[edit]** In `docs/pnr-pipeline.md`'s stage table, note that `dpl` and `cts` now
  end with a gated legality check, and that the default legalizer is the diamond legalizer
  (`PNR_DPL_LEGALIZER`). Verify: the table renders, and the row text matches the scripts.

## 3. Placement report (design D5)

- [x] 3.1 **[edit]** Extend `report_placement_state` in `run_pnr.sh`:
  - Add `legalizer <name>`, from the first `Legalizer:` line in `pnr_dpl.log`.
  - Add the `dpl` legality outcome, from `pnr_status.log`.
  - When the legalizer is `diamond` and no iteration table exists, word the illegal-cell figure
    `not logged by the diamond legalizer`.
  - Update the function's header comment.

  Verify: `bash -n` and `shellcheck run_pnr.sh`. Then run the function against two inputs:
  - copies of run `37996272102`'s `pnr_gpl.log`/`pnr_dpl.log` (negotiation; prints the
    iteration-0 count and `legalizer` unknown, as that run predates the `Legalizer:` line);
  - a hand-edited `pnr_dpl.log` with a `Legalizer: diamond` line and no table.

## 4. Lane input (ci-pipeline delta)

- [x] 4.1 **[edit]** In `.github/workflows/pnr.yml`, add the `dpl_legalizer` dispatch input:
  - Description: `'Legalizer for dpl/cts (empty = the default in scripts/pnr/common.tcl, diamond; negotiation = OpenROAD''s default)'`.
  - Pass it as `PNR_DPL_LEGALIZER=${{ github.event.inputs.dpl_legalizer || '' }}` on the
    `run_pnr.sh` line, next to `PNR_DIE_SCALE`.
  - Extend the comment block above that line.

  Verify: `actionlint .github/workflows/pnr.yml`, and the workflow has 8 inputs.

## 5. Validate on real data (Migration Plan steps 2–3)

- [ ] 5.1 **[long-run]** With the user's approval, dispatch `pnr.yml` from the change's branch
  with `resume_from_run=37996272102`, `resume_exclude="dpl cts grt grt_repaired"`, and all other
  inputs empty. Verify, from the run's summary and its `pnr-reports`:
  - the restore step reports a netlist-identity match;
  - `pnr_dpl.log` and `pnr_cts.log` contain `Legalizer: diamond`;
  - `pnr_status.log` shows `dpl ok` and `cts ok`, or a gated failure with violation counts.
- [ ] 5.2 Record in this file, under 5.1:
  - `dpl` and the two `cts` legalization runtimes, against 1 h 31 m / 2 h 40 m / 1 h 25 m for
    the negotiation legalizer in run `37996272102`;
  - utilization (`DPL-0009`), HPWL after `dpl` and `cts`, and `grt` congestion (total and
    Metal3) and WNS, against run `37996272102` (77.33 % / 95.27 %);
  - the `drt` outcome: guide processing passed or `DRT-0218` again, iteration-0 violation count,
    time per iteration, final status.

  If 5.1 fails a gated check or times out, stop: follow the Risks section of `design.md` and
  bring the user the result and the next lever before changing anything.
- [ ] 5.3 **[edit]** Record the finding and the 5.2 outcome in `docs/infra-plan.md` Phase 11:
  - the illegal-placement diagnosis and the per-run table from the proposal;
  - the `DRT-0218` abort in run `37996272102`;
  - the legalizer change and what the validation run showed.

  Also update `cts.tcl`'s history in the Appendix B gotchas, if it is cited there. Verify:
  Phase 11's checklist has a new checked item linking this change and the run IDs.

## 6. Results caveat

- [x] 6.1 **[edit]** In `docs/results/sha3-evaluation.md`'s Timing section, state that the `grt`
  figures on both sides come from placements that were not legal: 12,596 (reference) and 9,718
  (both arms) overlapping cells after `cts`, about 1 % of about 977 k. Add that this change
  fixes the flow, and that requoting is a separate decision. If `sha3-ppa.md` carries the same
  P&R figures, add the caveat to `scripts/sha3_ppa.py`'s note that generates it, not to the
  generated file, then regenerate. Verify: `python3 scripts/sha3_ppa.py` (or its documented
  invocation) reproduces `sha3-ppa.md` with only the note changed.
  — done. The generator now reads the counts from each run (`DPL-0005` in `pnr_cts.log`, which is
  uncapped; the JSON report caps markers at 10,000), so the note is not hard-coded. Correction to
  the figures above: the reference has 844,847 cells, not ~977 k, so the shares are 1.5 %
  (reference) and 1.0 % (both arms); the proposal now says 1.0–1.5 %. Regenerated with every
  committed input (synth 36447894410 / 37005575294 / 37218328058, P&R 37162759719 / 37108127061,
  repair 37512872714): before the edit the output was byte-identical to the committed file, and
  after it the diff is the two-line note only.

## 7. Integration

- [ ] 7.1 Run `openspec validate use-diamond-legalizer --strict` and confirm that the
  `pnr-flow` and `ci-pipeline` deltas still describe what the scripts do after groups 1–4.
  Verify: validation passes, and each scenario in the deltas maps to a code path or to 5.1's
  evidence.
