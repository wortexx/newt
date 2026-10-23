# Tasks

Tags: **[edit]** plain editing, checked with cheap local validation (actionlint, `openspec validate`, short OpenROAD calls in the `newt-eda:dev` image). **[eda]** loads a checkpoint in the image locally, minutes to an hour under emulation. **[long-run]** a P&R lane dispatch on the VM, about 20–24 h; always ask the user first.

## 1. SRAM Metal5 hold-back (design D1)

- [x] 1.1 **[eda]** Read `set_global_routing_region_adjustment`'s Tcl proc body and the C++ behind it in the `newt-eda:dev` build. Confirm its units (microns or DBU), that it applies only to the named layer, and that calling it repeatedly adds regions rather than replacing the last one. Record the result in design D1, and adjust D1 before any code if any of the three is false.
- [x] 1.2 **[edit]** Add `pnr_grt_sram_metal5_adjust` to `common.tcl` (`PNR_GRT_SRAM_METAL5_ADJUST`, default 0, validated as a number in [0, 1) with an error naming the variable). In `pnr_apply_routing_layers`, when it is above 0, call the region adjustment on Metal5 for every `RM_IHP*` instance's bounding box and log `SRAM Metal5 adjustment: <v> over <n> regions`. Comment it the way the Metal2 setting is. Verify in the image, on run `39244019401`'s `grt` checkpoint (scratchpad copy): with 0.55 the log reports 32 regions, an invalid value (`1.2`, `x`) errors before any routing call, and with the variable unset the proc issues the same commands as today.
- [x] 1.3 **[edit]** Pass `PNR_GRT_SRAM_METAL5_ADJUST` through `run_pnr.sh` (header doc block, next to `PNR_GRT_METAL2_ADJUST`). Add the `sram_metal5_adjust` dispatch input to `pnr.yml`, empty by default, wired like `grt_metal2_adjust`. Document it in `docs/pnr-pipeline.md`. Verify:
  - actionlint is clean;
  - with the input empty, the `pnr` step's rendered command is byte-identical to today's apart from one empty `PNR_GRT_SRAM_METAL5_ADJUST=` assignment.

## 2. Antenna repair mode (design D2)

- [x] 2.1 **[edit]** In `drt.tcl`, read `PNR_ANTENNA_REPAIR_MODE` (`full` default, `jumper`), reject anything else with an error naming the variable, call `repair_antennas` or `repair_antennas -jumper_only`, and record `antenna=skipped|full|jumper` in the `drt` status line. Verify in the image that `repair_antennas -jumper_only` is accepted on the `grt` checkpoint (stop after the call; do not route), and that an unknown mode fails before it.
- [x] 2.2 **[edit]** In `pnr.yml`, map `antenna_repair`: empty → skip, `1` → `full`, `jumper` → `jumper`. Add a step before P&R that fails on any other value, listing the accepted ones. Update the input's description, `run_pnr.sh`'s header and `docs/pnr-pipeline.md`. Verify:
  - actionlint is clean;
  - the rendered command for empty, `1` and `jumper` sets the expected `PNR_SKIP_ANTENNA_REPAIR` / `PNR_ANTENNA_REPAIR_MODE` pair, and empty stays as today apart from the new assignment;
  - the validation step rejects `2` (run the step's shell locally).

## 3. Antenna check and reporting (design D3)

- [x] 3.1 **[edit]** In `drt.tcl`, after `detailed_route` and before `save_checkpoint`, run `check_antennas -report_file ${report_dir}/${proj_name}_antenna.rpt` inside its own `catch`, logging a failure without changing the stage's outcome. Verify in the image on run `39244019401`'s `drt` checkpoint: the call logs `ANT-0002` 11,732 and `ANT-0001` 15,605, as the 2026-10-21 check did, and a forced error (bad report path) leaves the stage `ok`.
- [x] 3.2 **[edit]** Add `report_antenna_outcome` to `run_pnr.sh`, next to `report_drt_outcome` and run at the same point. It reads the last `ANT-0002` / `ANT-0001` from `pnr_drt.log` and logs `drt-antenna nets=<N> pins=<M>`, or `drt-antenna none`. Print the row and the report's name in `pnr.yml`'s summary. Verify against three fixture logs in the scratchpad: the 2026-10-21 `antenna.log` (expect 11732 / 15605), a log with `Found 0 net violations` (expect 0 / 0), and the baseline `pnr_drt.log` without ANT lines (expect `none`). Verify actionlint is clean.
- [x] 3.3 **[edit]** Document the new status row and report in `docs/pnr-pipeline.md`'s reports section. Open the PR with groups 1–3 and the change artifacts. Verify `openspec validate drc-clean-sram-metal5-and-antenna --strict` passes. After the user merges, the run dispatches on `main`.

## 4. Measured run (design D4, D5)

- [ ] 4.1 **[long-run]** *(ask the user first)* Dispatch with D4's inputs: `resume_from_run=39244019401`, `resume_exclude=grt grt_repaired drt final`, `die_scale=1.25`, `gpl_density=0.50`, `grt_metal2_adjust=0.60`, `sram_metal5_adjust=0.55`, `antenna_repair=1`, `drt_end_iter=28`. Save its `pnr-reports` under `target/ihp13/openroad/out/ci-<run>/`. Verify:
  - `cts` and earlier were restored, not re-run;
  - `grt.tcl` and `drt.tcl` logged the SRAM adjustment over 32 regions;
  - `drt ok antenna=full`, and `drt-violations` and `drt-antenna` rows are present;
  - `final ok` with the DEF artifact.
  - *Ran 2026-10-22 as run `39696194006`:* `cts` and earlier restored, SRAM adjustment logged over 32 regions in `grt` and `drt`. `drt` hit its 24 h timeout inside `repair_antennas` (diode legalization did not converge, then a silent hang), so `drt ok antenna=full` and `final ok` were not met. Reports are in `target/ihp13/openroad/out/ci-39696194006/`. The D5 retry is 4.3.
- [x] 4.2 **[edit]** Compare with run `39244019401` per D4: the router's count after iteration 28 (138), violations inside SRAM footprints (from `basilisk_route_drc.rpt`), antenna nets and pins (11,732 / 15,605), `grt` overflow (2,529), WNS at `grt` (−11.02 ns), and `repair_antennas` time and insertions. Record it in docs/infra-plan.md under the 2026-10-21 analysis. Then pick D5's row and ask the user before any follow-up dispatch.
- [x] 4.3 **[long-run]** *(only if 4.2 lands on a D5 retry row; ask the user first)* Dispatch the retry D5 names (Metal5 0.70, hold-back without antenna repair, or `antenna_repair=jumper`), from the checkpoint D5 names. Verify and record it as in 4.1–4.2.
  - *Ran 2026-10-23 as run `39906592139`* (jumper-only, from `39696194006`'s `grt`): `drt ok antenna=jumper`, `final ok`, DEF published. 8 router violations after iteration 28 (5 inside two SRAMs), antenna 8,627 nets / 11,287 pins. Reports are in `target/ihp13/openroad/out/ci-39906592139/`, and the record is in docs/infra-plan.md.

## 5. Close-out

- [x] 5.1 **[edit]** Check that docs/infra-plan.md states the outcome and the next step: adopting the defaults together with the thesis requote, the PDN lever, or the antenna follow-up. Verify `openspec validate drc-clean-sram-metal5-and-antenna --strict` passes.
