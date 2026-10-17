# Tasks

Tags: **[edit]** plain editing, cheap to verify. **[eda]** needs the EDA tools locally (Docker image). **[long-run]** dispatches a P&R lane run on the self-hosted VM: ask the user before each dispatch, and check that the VM's `start` job runs.

## 1. Lane inputs (design D1)

- [x] 1.1 **[edit]** In `.github/workflows/pnr.yml`, add the `workflow_dispatch` inputs `drt_end_iter` (empty = 5) and `antenna_repair` (`1` = run it; empty = skip). Wire them into the `pnr` step's environment as `PNR_DRT_END_ITER=${{ github.event.inputs.drt_end_iter || '5' }}` and `PNR_SKIP_ANTENNA_REPAIR` (`0` when the input is `1`, else `1`). Comment each input the way `skip_grt_repair` is commented. Verify:
  - `actionlint` (or the infra lane's workflow lint) is clean;
  - with both inputs empty, the rendered `pnr` step environment is byte-identical to today's;
  - `docs/pnr-pipeline.md` lists the two inputs next to the existing ones.

## 2. Router-count reporting (design D2)

- [x] 2.1 **[edit]** Add `report_drt_outcome` to `target/ihp13/openroad/run_pnr.sh`, called after `drt` the way `report_placement_state` is called after `dpl`. It parses `pnr_drt.log`:
  - every `DRT-0199 Number of violations = N` line, one per iteration;
  - the last `Viol/Layer` table.

  It writes `reports/basilisk.drt.violations.txt`, appends `drt-violations final=<N> iterations=<k> trajectory=<n0,…>` to `pnr_status.log`, and echoes both into the step summary. In `drt.tcl`, drop the `drc_report_lines` count and keep the report file. Verify by running the function against run `38473439796`'s saved `pnr_drt.log` (`target/ihp13/openroad/out/ci-38473439796/`):
  - `final=715558 iterations=6 trajectory=1928860,1314060,1247623,847112,751136,715558`;
  - the table matches the log's last `Viol/Layer` block;
  - a log with no `DRT-0199` line writes `drt-violations none` and does not fail the run.
- [x] 2.2 **[edit]** Make the step summary show the `drt-violations` line where it shows `drt`'s status today. Verify: the summary text for the saved run, rendered locally, contains the router's final total, not 21,110.

## 3. Land the lane change

- [x] 3.1 **[edit]** Open the PR with groups 1–2 and the change directory. The fast lane must stay green (`pnr.yml` is not part of it; the infra lane validates the workflow). Verify the PR's diff touches only `pnr.yml`, `run_pnr.sh`, `drt.tcl`, `docs/pnr-pipeline.md` and this change. After the user merges, the probes dispatch on `main`.

## 4. Phase 1: probe sweep (design D3, D4)

- [x] 4.1 **[long-run]** *(ask the user first)* Dispatch P2: `die_scale=1.25`, `gpl_density=0.50`, `stop_after=drt`, `drt_end_iter=1`, other inputs empty. Save its `pnr-reports` under `target/ihp13/openroad/out/ci-<run>/`. Verify:
  - every gated stage is `ok`;
  - `gpl` converged (placement report);
  - legal after `dpl` and `cts`;
  - record iteration-0/1 violations by type and layer, `grt` demand and overflow, utilization, WNS, and the wire per layer.

  If floorplan or PDN fails at 1.25, stop and report.
- [x] 4.2 **[edit]** Compare P2 with probe B (iteration 0: 1,928,860; iteration 1: 1,314,060) against D3's thresholds. Record the result, and the choice of next probe, in `docs/infra-plan.md` Phase 11. If P2 passes, the next probe is P1. Otherwise it is P3.
- [ ] 4.3 ~~**[long-run]** *(ask the user first)* Dispatch the probe 4.2 chose (P1: `die_scale=1.10`, `gpl_density=0.60`; or P3: `die_scale=1.40`, `gpl_density=0.45`) with the same other inputs. Verify the same points as 4.1.~~ **Skipped 2026-10-17, user decision:** P2 missed the go threshold, but Metal2 holds 84 % of what is left, which more spreading (P3) is unlikely to fix. See Phase 11.
- [x] 4.4 **[edit]** Pick the best setting, or none, against D3's thresholds. Record it with the probe table in Phase 11, and ask the user to confirm the pick before Phase 2. If no probe reaches the go threshold, skip group 5 and go to group 6. **Done 2026-10-17:** none reaches the go threshold; P2 (1.25, 0.50) is the best measured. Group 5 skipped.

## 5. Phase 2: route to convergence (design D5)

- [ ] 5.1 **[long-run]** *(ask the user first)* Dispatch the chosen setting with `drt_end_iter=64` and `antenna_repair=1`, no `stop_after`. Save `pnr-reports` and the DEF artifact name. Verify the router's final total (`drt-violations final=`) and the trajectory. Success is `final=0`, with `final` writing the DEF.
- [ ] 5.2 **[long-run]** *(only if 5.1's antenna repair hangs or fails; ask the user first)* Re-dispatch resuming 5.1's `grt` checkpoint, `antenna_repair` empty, same budget. Verify as in 5.1, and record antenna repair as an open lever.
- [ ] 5.3 **[edit]** Record the outcome in Phase 11: converged or not, iterations, runtime, peak memory, WNS, and the die, density and utilization. If it converged, ask the user whether to adopt the settings as the lane's defaults. That would be its own task with a scheduled-run check, since it changes every later run's figures.

## 6. Phase 3: decision (design D6)

- [x] 6.1 **[edit]** If routing has not converged, write the probe evidence and the three candidate levers into Phase 11, then ask the user which to pursue. Add the chosen lever's tasks here, or open a follow-up change, before any further dispatch. If routing converged, mark this task done with "not needed". **Done 2026-10-17:** the user chose holding more of Metal2 back from global routing (design D7); tasks 6.2–6.6.
- [x] 6.2 **[edit]** In `common.tcl`, add `pnr_grt_metal2_adjust` (`PNR_GRT_METAL2_ADJUST`, default 0.30, validated as a number in [0, 1)). `pnr_apply_routing_layers` applies it to Metal2 alone, keeps Metal3 at 0.30, and logs both values. Add the `grt_metal2_adjust` input to `pnr.yml` the D1 way, document it in `run_pnr.sh`'s header and `docs/pnr-pipeline.md`. Verify:
  - actionlint is clean;
  - with the input empty, the `pnr` step's rendered command is byte-identical to today's apart from one empty `PNR_GRT_METAL2_ADJUST=` assignment;
  - the Tcl is checked against the OpenROAD build in the `newt-eda` image (`set_global_routing_layer_adjustment` on a single layer).
- [x] 6.3 **[edit]** Open the PR with 6.2 and the updated change artifacts. After the user merges, the probe dispatches on `main`.
- [x] 6.4 **[long-run]** *(ask the user first)* Dispatch P2-M: `resume_from_run=38931700180`, `resume_exclude=grt grt_repaired drt`, `grt_metal2_adjust=0.60`, `stop_after=drt`, `drt_end_iter=1`, other inputs empty. Save its `pnr-reports` under `target/ihp13/openroad/out/ci-<run>/`. Verify:
  - the restore reused P2's placement: `cts` and earlier are skipped on resume;
  - `grt.tcl` logged Metal2 0.60;
  - record `grt` usage per layer and overflow, and violations after iterations 0 and 1 by type and layer, against P2.
- [x] 6.5 **[edit]** Compare with P2 against D3's thresholds and record it in Phase 11. If it reaches the go threshold, ask the user to confirm and continue at group 5 with P2's die and density plus this adjustment (5.1's dispatch gains `grt_metal2_adjust`). Otherwise pick D7's second value and ask before dispatching it, or report that cell padding is next. **Done 2026-10-17:** P2-M missed the go threshold (932,994 after iteration 0); recorded in Phase 11. The user chose cell padding over D7's second value (design D8).
- [ ] 6.6 ~~**[long-run]** *(only if 6.5 calls for a second value; ask the user first)* Dispatch it the same way as 6.4 and record it the same way as 6.5.~~ **Skipped 2026-10-17, user decision:** cell padding instead (6.7–6.10).
- [x] 6.7 **[edit]** Add `pnr_cell_pad_sites` (`PNR_CELL_PAD_SITES`, default 0, validated as a non-negative integer) to `common.tcl`. Apply it as design D8 says: both `global_placement` passes in `gpl.tcl`, `pnr_detailed_placement`, and a reset before `filler_placement` in `final.tcl`. Log the value in each stage that applies it. Add the `cell_pad_sites` input to `pnr.yml` the D1 way. Document it in `run_pnr.sh`'s header and `docs/pnr-pipeline.md`. Verify:
  - actionlint is clean;
  - with the input empty, the `pnr` step's rendered command is byte-identical to today's apart from one empty `PNR_CELL_PAD_SITES=` assignment;
  - in the `newt-eda` image, the padding commands are accepted and invalid values are rejected.
- [x] 6.8 **[edit]** Open the PR with 6.7 and the updated change artifacts. After the user merges, the probe dispatches on `main`.
- [x] 6.9 **[long-run]** *(ask the user first)* Dispatch P2-P: `die_scale=1.25`, `gpl_density=0.50`, `cell_pad_sites=1`, `stop_after=drt`, `drt_end_iter=1`, other inputs empty. Save its `pnr-reports` under `target/ihp13/openroad/out/ci-<run>/`. Verify the same points as 4.1, plus `Cell padding: 1` in the `gpl`, `dpl` and `cts` logs, and record it against P2. **Done 2026-10-17: run `39031099535` failed in `cts`.** Padding was applied in all three stages. `gpl` converged and `dpl` passed its padded legality check at 43.6 %. Then `cts` could not legalize 25 of 983,276 cells after inserting buffers (`DPL-0036`). Recorded in Phase 11. The user chose a fallback (design D8 amendment, tasks 6.11–6.13).
- [ ] 6.10 **[edit]** *(after 6.13)* Compare with P2 against D3's thresholds and record it in Phase 11. If it reaches the go threshold, ask the user to confirm, then continue at group 5 with P2's die and density plus this padding (5.1's dispatch gains `cell_pad_sites`). Otherwise, if it improved, ask before trying 2 sites the same way. If not, report the evidence and decide the next step with the user.
- [x] 6.11 **[edit]** Add `pnr_legalize_with_pad_fallback` to `common.tcl` as the D8 amendment describes, and use it for every legalization in `cts.tcl` and `grt_repair.tcl`. Their status lines carry `cell_pad_fallbacks=N` when it is above 0. Update `docs/pnr-pipeline.md`. Verify:
  - with padding 0, the calls are the same `detailed_placement` calls as before;
  - against a stubbed `detailed_placement`, the fallback happens only on `DPL-0036` with padding on, other errors are raised, and a failing retry is raised.
- [x] 6.12 **[edit]** Open the PR with 6.11 and the updated change artifacts. After the user merges, the probe dispatches on `main`.
- [ ] 6.13 **[long-run]** *(ask the user first)* Dispatch P2-P2: `resume_from_run=39031099535`, `resume_exclude=cts grt grt_repaired drt`, `die_scale=1.25`, `gpl_density=0.50`, `cell_pad_sites=1`, `stop_after=drt`, `drt_end_iter=1`. Verify that `cts` passes its gated check, and record how many fallbacks it took and how many cells each one listed. Then do 6.10 with this run.

## 7. Close-out

- [ ] 7.1 **[edit]** `openspec validate drc-clean-pnr --strict`. Check Phase 11 for the requote follow-up: re-running the reference and both arms on the converged settings is named as the next change, and the safety-net figures stay as they are until it lands.
