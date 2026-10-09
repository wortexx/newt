# Tasks

Legend: **[edit]** plain editing; **[eda ~25 min]** needs the `newt-eda` image (OpenROAD, no synthesis or P&R; about 25 min per netlist under amd64 emulation); **[long]** needs a P&R lane run on the self-hosted VM.

## 1. SoC power probe (design D2)

- [x] 1.1 [edit] Add `target/ihp13/openroad/scripts/soc_power_probe.tcl` with an SPDX header (SHL-0.51). It sets `pdk_dir`, sources `scripts/init_tech.tcl`, reads `$::env(NETLIST)`, links `iguana_chip` and reads `src/basilisk.sdc`. It then runs, in order:
  - default-activity `report_power` with `sta::set_debug power_activity 1`;
  - `report_power -instances [get_cells *]` into `$::env(OUT)/inst.txt`;
  - `set_power_activity -global -activity 0.1 -duty 0.5`, `report_power`, `unset_power_activity -global`.

  Verify: the script parses (`openroad -no_init -exit` on a file that only sources it with `NETLIST` unset fails at `read_verilog`, not with a Tcl syntax error).
- [x] 1.2 [edit] Add `scripts/soc_power_agg.py` (SPDX header). It sums `inst.txt` by the instance-name prefix before the first `/`, and by the first three dotted components for flat glue. It prints total and switching mW per group, one column per given dump. Verify: on a hand-made three-line dump it prints the expected sums.
- [x] 1.3 [edit] Add the `soc-power-probe` target to `target/ihp13/openroad/openroad.mk` (`NETLIST=...`, output in `$(OPENROAD_DIR)/out/power-probe/<netlist basename's parent dir>`). It runs the probe, then the aggregator. Verify: `make -n soc-power-probe NETLIST=/x/basilisk.yosys.v` prints both commands with the right paths.
- [x] 1.4 [eda ~25 min] Run `make soc-power-probe` on the both-arms `basilisk-netlist` artifact (synth run `37218328058`). Verify against the design's table:
  - default total 0.610 W, 50 passes;
  - uniform total 2.006 W;
  - the aggregator shows `i_keccak_cvxif` and CVA6 switching at about zero.
- [x] 1.5 [edit] Document the probe in the `soc-power-probe` target's comment block in `openroad.mk` (the directory has no README): how to fetch a netlist (`gh run download <run> -n basilisk-netlist`), the run time, and that the default-activity number it prints is a diagnostic, not a power figure. Verify: the documented commands match 1.3 and 1.4 as run.

## 2. Lane power reports (design D1, spec "Power reports state their activity assumption")

- [x] 2.1 [edit] In `report_metrics` (`target/ihp13/openroad/scripts/reports.tcl`), wrap the `report_power` / `report_power_metric` pair in `set_power_activity -global -activity 0.1 -duty 0.5` … `unset_power_activity -global`. Before the table, write a line into the report naming the activity, the duty, the fastest clock's period, and "uniform activity, comparative only, not workload power". Verify: `git diff` shows only that section changed.
- [x] 2.2 [eda ~25 min] Check that the edited `report_metrics` works outside the lane, with no P&R run. Load the both-arms netlist as in 1.1, set `report_dir` to a temp directory, and call `report_metrics probe false`. Verify:
  - `probe.rpt` contains the label line and a total of 2.006 W;
  - after the call, `report_power` without a setting gives the default 0.610 W again, which shows the setting doesn't leak.
- [x] 2.3 [edit] Rewrite `docs/infra-plan.md` Phase 17 around the measured diagnosis (design Context), and mark it done:
  - close "diagnose", "isolate" and "re-measure" with the probe results;
  - close "fix or document" with 2.1;
  - name this change and its commit as the point after which lane power figures are uniform-activity and not comparable with earlier runs.

  Also update the Phase ordering line for Phase 17. Verify: no unchecked item remains under Phase 17.
- [ ] 2.4 [long, optional] On the next P&R lane run that happens anyway, check that a stage report (for example `basilisk.pre_place.rpt`) carries the label line and a uniform-activity total. Record the run number in Phase 17. Do not dispatch a run only for this.

## 3. Results docs (design D3)

- [x] 3.1 [edit] In `scripts/sha3_ppa.py`, replace the reason in the "SoC power: not reported" paragraph:
  - the reason is that OpenSTA's default activity does not converge on this SoC (50-pass cap; 0.997 / 9.18 / 0.610 W for reference / coprocessor only / both arms);
  - under uniform activity, adding both arms costs +14.6 %, labelled comparative only;
  - pointer to `docs/infra-plan.md` Phase 17.

  Regenerate `docs/results/sha3-ppa.md`. If the generator's run directories aren't available locally, apply the identical text to the generated file by hand and say so in the commit. Verify: `git diff docs/results/sha3-ppa.md` changes only that paragraph.
- [x] 3.2 [edit] Update the SoC-power paragraph and the line-330 caveat in `docs/results/sha3-evaluation.md` to match 3.1, keeping "SoC power is not reported". Verify: `grep -n "not investigated\|stops propagating" docs/results/sha3-evaluation.md docs/results/sha3-ppa.md scripts/sha3_ppa.py` finds nothing about SoC power.

## 4. Integration check

- [x] 4.1 [edit] Run `openspec validate pin-soc-power-activity --strict`, then run `grep -rn "Phase 17" docs/ scripts/` to check that every reference describes the closed finding consistently. Verify: validation passes, and no reference still calls Phase 17 open or uninvestigated.
