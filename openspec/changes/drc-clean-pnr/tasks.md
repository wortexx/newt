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

- [ ] 4.1 **[long-run]** *(ask the user first)* Dispatch P2: `die_scale=1.25`, `gpl_density=0.50`, `stop_after=drt`, `drt_end_iter=1`, other inputs empty. Save its `pnr-reports` under `target/ihp13/openroad/out/ci-<run>/`. Verify:
  - every gated stage is `ok`;
  - `gpl` converged (placement report);
  - legal after `dpl` and `cts`;
  - record iteration-0/1 violations by type and layer, `grt` demand and overflow, utilization, WNS, and the wire per layer.

  If floorplan or PDN fails at 1.25, stop and report.
- [ ] 4.2 **[edit]** Compare P2 with probe B (iteration 0: 1,928,860; iteration 1: 1,314,060) against D3's thresholds. Record the result, and the choice of next probe, in `docs/infra-plan.md` Phase 11. If P2 passes, the next probe is P1. Otherwise it is P3.
- [ ] 4.3 **[long-run]** *(ask the user first)* Dispatch the probe 4.2 chose (P1: `die_scale=1.10`, `gpl_density=0.60`; or P3: `die_scale=1.40`, `gpl_density=0.45`) with the same other inputs. Verify the same points as 4.1.
- [ ] 4.4 **[edit]** Pick the best setting, or none, against D3's thresholds. Record it with the probe table in Phase 11, and ask the user to confirm the pick before Phase 2. If no probe reaches the go threshold, skip group 5 and go to group 6.

## 5. Phase 2: route to convergence (design D5)

- [ ] 5.1 **[long-run]** *(ask the user first)* Dispatch the chosen setting with `drt_end_iter=64` and `antenna_repair=1`, no `stop_after`. Save `pnr-reports` and the DEF artifact name. Verify the router's final total (`drt-violations final=`) and the trajectory. Success is `final=0`, with `final` writing the DEF.
- [ ] 5.2 **[long-run]** *(only if 5.1's antenna repair hangs or fails; ask the user first)* Re-dispatch resuming 5.1's `grt` checkpoint, `antenna_repair` empty, same budget. Verify as in 5.1, and record antenna repair as an open lever.
- [ ] 5.3 **[edit]** Record the outcome in Phase 11: converged or not, iterations, runtime, peak memory, WNS, and the die, density and utilization. If it converged, ask the user whether to adopt the settings as the lane's defaults. That would be its own task with a scheduled-run check, since it changes every later run's figures.

## 6. Phase 3: decision (design D6)

- [ ] 6.1 **[edit]** If routing has not converged, write the probe evidence and the three candidate levers into Phase 11, then ask the user which to pursue. Add the chosen lever's tasks here, or open a follow-up change, before any further dispatch. If routing converged, mark this task done with "not needed".

## 7. Close-out

- [ ] 7.1 **[edit]** `openspec validate drc-clean-pnr --strict`. Check Phase 11 for the requote follow-up: re-running the reference and both arms on the converged settings is named as the next change, and the safety-net figures stay as they are until it lands.
