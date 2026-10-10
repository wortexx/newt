# Design

## Context

The staged flow calls `detailed_placement` in six places:

- `dpl.tcl` once, with an empty `DPL_ARGS`;
- `cts.tcl` twice, after clock-tree insertion and after `repair_timing -setup`;
- `grt_repair.tcl` three times, only when post-route repair is not skipped.

None of them passes a legalizer flag, so all of them get OpenROAD `2c56926`'s negotiation legalizer. It ends with `DPL-0701 NegotiationLegalizer did not fully converge` and returns normally. The only legality check is `check_placement` at the end of `cts.tcl`, and its `DPL-0033` error is caught and logged as a warning (`cts.tcl:63-80`). `final.tcl` has another caught check, but no run has reached it.

`detailed_placement` in this build accepts `-use_diamond_legalizer`, plus `-max_displacement`, `-site_search_window` and `-row_search_window` (checked with `help detailed_placement` in `ghcr.io/wortexx/newt-eda:dev`). The diamond legalizer is the pre-2025 one. It logs `DPL-0005 Diamond search max displacement`, and it raises an error when it cannot place a cell instead of returning with overlaps.

Settings follow the existing pattern in `common.tcl`:
- a Tcl variable with a default (`pnr_gpl_keep_resize`, `pnr_die_scale`);
- an environment override (`PNR_*`), documented in `run_pnr.sh`'s header;
- a `pnr.yml` dispatch input passed on the `run_pnr.sh` command line, with an empty value meaning "default".

`pnr.yml` has 7 dispatch inputs, so this change's 8th is within GitHub's limit of 10.

## Goals / Non-Goals

**Goals:**
- One place that decides how the flow legalizes, so the stages can never disagree about it.
- A run that cannot legalize stops at the stage that failed to legalize, with the evidence kept.
- A validation run on real data that answers two questions: does the diamond legalizer legalize this design on the taped-out die, and does `drt` then get past guide processing?

**Non-Goals:**
- Tuning `-max_displacement` or the search windows up front. That's done only if the validation run shows the default window failing.
- Changing what `final.tcl` checks. `final` is best-effort, and its check stays non-fatal.

## Decisions

### D1. One wrapper for every legalization

`common.tcl` gains `pnr_detailed_placement {args}`. It appends `-use_diamond_legalizer` when `pnr_dpl_legalizer` is `diamond`, logs `Legalizer: <name>` through `utl::report`, and calls `detailed_placement`. All six call sites use it. `pnr_dpl_legalizer` is read from `PNR_DPL_LEGALIZER`. An empty value means the default, `diamond`. Any value other than `diamond` or `negotiation` is a Tcl error in every stage, so a typo cannot silently fall back to a default.

*Alternative:* set the flag at each call site. Rejected: six call sites across three files would drift. `grt_repair.tcl` already has three bare calls that nobody revisited when `dpl.tcl` gained `DPL_ARGS`.

### D2. Diamond is the default, not opt-in

Scheduled and tag runs have to get a legal placement without anyone remembering a dispatch input. The weekly run is the one that goes through `drt`. `negotiation` stays selectable, so the old behaviour can be reproduced for comparison or to bisect a regression.

*Alternative:* opt-in first, flip the default after validation. Rejected: the validation run sets the input anyway, so opt-in only adds a second PR. If the validation run fails, the change is not merged as it is (see Migration Plan).

### D3. Legality is checked by a gated helper after `dpl` and `cts`

`common.tcl` gains `pnr_check_placement {stage}`. It runs `check_placement -verbose -report_file_name ${report_dir}/${proj_name}_${stage}_check_placement.rpt` and raises an error when the check fails. The error message carries the per-category violation counts (overlap, padding, blocked layers), read from the report's JSON. The stage's existing `catch` then records `<stage> failed <message>` through `pnr_status`, and `run_pnr.sh` sees a failed gated stage.

- `dpl.tcl` calls it after `optimize_mirroring` and before `save_checkpoint`.
- `cts.tcl` replaces its caught check with it, at the same point.

A failed check therefore leaves no checkpoint for that stage, so a later resume cannot pick up an illegal placement as if it were good. The report file is kept in `reports/`, which the lane uploads.

*Alternative:* check before `grt` only. Rejected: a legalization failure in `dpl` would then cost the 7 h `cts` stage before it is noticed.

*Alternative:* save the checkpoint even when the check fails, for diagnosis. Rejected: the report file already holds the violation list and positions, and the predecessor checkpoint (`gpl2` or `dpl`) is kept. That predecessor is exactly what a re-run with a different legalizer setting needs.

### D4. `grt_repair` uses the wrapper but adds no gate

`grt_repair` is best-effort and runs only on request. Its three calls go through `pnr_detailed_placement`, so they use the same legalizer. A diamond failure there fails `grt_repair`, which is already a non-gating outcome. No legality check is added there: the incremental `global_route` that follows each call already depends on the result, and the stage cannot change the run's exit status anyway.

### D5. The placement report reads the legalizer and the check from the logs

`report_placement_state` in `run_pnr.sh` adds:
- `legalizer <name>`, from the `Legalizer:` line in `pnr_dpl.log`;
- `legality check passed` or the failure line, from `pnr_status.log`'s `dpl` entry.

The illegal-cell figure keeps its current awk, which reads the negotiation legalizer's iteration table. When no table exists, it already prints `none reported`. With the diamond legalizer, the wording becomes `not logged by the diamond legalizer` instead. No new log parsing is invented for a count the diamond legalizer does not print.

### D6. No retries for the new failure

`STAGE_RETRIES` stays `0` for `dpl` and `cts`. Legalization is deterministic for a given checkpoint and setting, so a retry would repeat the same failure at the same cost.

## Risks / Trade-offs

- **[Diamond cannot place every cell at 68–71 % utilization]** → The stage fails with `DPL-0036`-class errors and the lane goes red at `dpl` or `cts`. Mitigation: the validation run finds this before merge. The next levers, in order, are a wider `-max_displacement` (via `DPL_ARGS`) and then `die_scale=1.10`. Each is a separate decision, recorded in Phase 11.
- **[Diamond is slower than negotiation on about 977 k cells]** → `dpl` (4 h) or `cts` (8 h) times out. Mitigation: the validation run measures both. Timeouts are raised in this change only if it shows a need.
- **[Blocked-layer violations survive any legalizer]** → If the 53–63 cells on blocked layers come from macro or PDN keep-outs that `detailed_placement` does not honour, the check would fail regardless of legalizer. Mitigation: the validation run's check report names those cells. If they persist, they're investigated before merge. Making the blocked-layer category non-fatal is the fallback, decided then and recorded here.
- **[P&R figures move]** → Placement, wirelength, timing and congestion all change, so earlier `grt` figures are not comparable with later ones (proposal: BREAKING). Mitigation: the docs note the break and the date. Requoting the thesis figures is a separate decision.
- **[A change to the gated stages can turn the weekly run red]** → That is the intended outcome when placement is illegal. The run's summary names the failed stage and its counts.

## Migration Plan

1. Implement D1–D6 on a branch. Cheap checks: tclsh parse of the stage scripts, `run_pnr.sh` dry-run, `actionlint`.
2. Dispatch the lane from the branch, resuming from run `37996272102`:
   - `resume_from_run=37996272102`
   - `resume_exclude="dpl cts grt grt_repaired"`
   - all other inputs empty, so the legalizer is the new default, `diamond`.

   The restored `gpl2` checkpoint was built from the same netlist (`main` at `b21a9b2`; the netlist-identity check enforces this). The run therefore re-runs only `dpl` onwards, and a gated failure stops it early on its own.
3. If `dpl` and `cts` pass their checks, the same run continues through `grt` and `drt`. Record:
   - legalizer runtimes;
   - `grt` congestion and WNS against the illegal-placement run;
   - whether `drt` passes guide processing, and its iteration-0 violation count.
4. Merge only after step 3 shows legal placement. If diamond fails, or if `drt` still aborts with `DRT-0218` on a legal placement, record the result in Phase 11 and in this change. The fix then needs a revised design (`-max_displacement`, `die_scale`, or a different diagnosis) before merge.

Rollback: setting `PNR_DPL_LEGALIZER=negotiation` restores the old legalizer. The gated check still applies, so a full rollback of the check means reverting the change.
