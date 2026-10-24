# Tasks

Tags:
- **[edit]** Plain editing, checked with cheap local validation: actionlint, `openspec validate`, `bash -n`, short OpenROAD calls in the `newt-eda:dev` image, or the generator run on saved reports.
- **[long-run]** A P&R or synth dispatch on the VM, about 16 h per P&R run. Always ask the user first.

## 1. New defaults (design D1)

- [x] 1.1 **[edit]** In `common.tcl`, set `pnr_die_scale` 1.25, `pnr_gpl_density` 0.50, `pnr_grt_metal2_adjust` 0.60 and `pnr_grt_sram_metal5_adjust` 0.55. Update each one's comment with the run it was measured on. In `drt.tcl`, make `PNR_ANTENNA_REPAIR_MODE` default to `jumper` and update its header. Verify in the image:
  - sourcing `common.tcl` with no `PNR_*` variables set gives the four new values;
  - each `PNR_*` override still wins;
  - `drt.tcl` with no mode set logs `Antenna repair: jumpers only` on a stub run (`repair_antennas` and `detailed_route` stubbed).
- [x] 1.2 **[edit]** In `pnr.yml`:
  - map `antenna_repair`: empty or `jumper` → jumper-only, `1` → full, `skip` → `PNR_SKIP_ANTENNA_REPAIR=1`;
  - make the `start` job's check accept exactly empty, `jumper`, `1` and `skip`;
  - set the `drt_end_iter` default to 28;
  - update the descriptions of `die_scale`, `gpl_density`, `grt_metal2_adjust`, `sram_metal5_adjust`, `antenna_repair` and `drt_end_iter`, and the step comments.

  Verify:
  - actionlint 1.7.10 is clean;
  - the rendered `pnr` command for empty, `jumper`, `1` and `skip` sets the expected skip/mode pair, and empty sets `PNR_DRT_END_ITER=28`;
  - the check step's shell rejects `2` and `full` and accepts the four values.
- [x] 1.3 **[edit]** Update `run_pnr.sh`'s header and `docs/pnr-pipeline.md`: the new defaults, the `skip` value, the new antenna default, and a note to set the old values explicitly when resuming a checkpoint made before this change. Verify with `bash -n run_pnr.sh`, and `grep -n '1\.10\|0\.65\|0\.30' docs/pnr-pipeline.md run_pnr.sh pnr.yml` hits no stale default statement.

## 2. Generator (design D5)

- [x] 2.1 **[edit]** In `scripts/sha3_ppa.py`:
  - parse the settings: the `Die:` line, the `gpl` target density, the `grt` layer and SRAM Metal5 adjustments, and the `drt` status detail;
  - build the flow sentence from them instead of the hard-coded `stop_after=grt`;
  - make `pnr_comparable` refuse runs whose settings differ, naming the setting.

  Verify on saved reports:
  - the 1.10 pair (`ci-38395368038`, `ci-38772313345`) still generates, and its flow sentence states die 1.10, density 0.65 and Metal2 0.30;
  - a copy of one side with its density line changed fails with a message naming `gpl density` and both values.
- [x] 2.2 **[edit]** Add the routed outcome to the P&R section, from the `drt-violations` and `drt-antenna` status rows: router count with its iteration count, and antenna net and pin counts. A missing row or a `none` row reads "no routed design" or "no antenna count", never zero. Verify:
  - on `ci-39906592139`'s `pnr_status.log`: `8` after 29 iterations, `8627` / `11287`;
  - on `ci-39696194006`'s: no routed design;
  - on the 1.10 pair (no `drt`): no routed design for both, and the rest of the section unchanged.

## 3. Land the defaults

- [ ] 3.1 **[edit]** Open the PR with groups 1–2 and this change's artifacts. Verify `openspec validate adopt-drc-clean-defaults-and-requote --strict` passes and the fast lane is green. After the user merges, the runs in group 4 dispatch on that `main` commit.

## 4. The requote pair (design D2, D3, D4)

- [ ] 4.1 **[long-run]** *(ask the user first)* Dispatch `pnr.yml` on `main` with no inputs. Save its `pnr-reports` under `target/ihp13/openroad/out/ci-<run>/`. Verify:
  - every stage ran (none restored);
  - legal after `dpl` and `cts`;
  - `Die:` at core scale 1.25;
  - `SRAM Metal5 adjustment: 0.55 over 32 regions`;
  - `drt ok droute_end_iter=28 antenna=jumper`, a `drt-antenna` row, and `final ok` with the DEF.
- [ ] 4.2 **[edit]** Compare 4.1 with the measured chain per D2: `grt` WNS and overflow, the router count after iteration 28, antenna counts, and `DPL-0009` after `cts`. Record it in `docs/infra-plan.md`. A router count above 1,000 or WNS more than 1 ns off the chain's −12.05 ns is a stop: report it and ask the user before 4.3.
- [ ] 4.3 **[edit]** Rebase `pnr-reference-no-arms` onto 4.1's commit. Verify `git diff <commit> --stat` shows only the four reference files, and the branch still lints (`make ig-hw-cva6` and the fast lane's Verilator lint in the image, 0 `%Error`). Push it (force, since it is a never-merged measurement branch).
- [ ] 4.4 **[long-run]** *(ask the user first)* Dispatch `pnr.yml` on `pnr-reference-no-arms` with no inputs. Save its `pnr-reports`. Verify:
  - the same points as 4.1, with the same `Die:` line as 4.1;
  - its uploaded `synth-key.txt` equals run `38772313345`'s (`synth-c9179ea7…`).

  If the keys differ, stop and ask before dispatching `synth.yml` on the branch for a metrics comparison (D3). If `drt` fails, record it and ask (D4).

## 5. Results docs (design D6)

- [ ] 5.1 **[edit]** Regenerate `docs/results/sha3-ppa.md` with `--pnr <4.1 dir> --pnr-ref <4.4 dir>` and the page's other inputs unchanged. Verify with `git diff`:
  - only the P&R section, the achieved-period column and the energy sentences change;
  - every number in the P&R section traces to one of the two artifacts.
- [ ] 5.2 **[edit]** Update `docs/results/sha3-evaluation.md`:
  - the timing row and prose, with the new WNS pair, run IDs, settings and routed outcome;
  - the achieved period and the energy figures, copied from 5.1;
  - the worst-path attribution, re-checked from the new reports;
  - the 1.10 pair moved into a dated "earlier flow settings" note with its settings and the reason;
  - the "No signoff layout" limitation updated with the routed and antenna counts.

  Verify: `grep -n '19.96\|8.96\|8.39\|38395368038\|38772313345' docs/results/` hits only the earlier-settings note, and the superseded illegal-placement note is unchanged.
- [ ] 5.3 **[edit]** In `docs/infra-plan.md`, tick the "Next change" item with both run IDs, and update the §0 "Basilisk WNS" row. Verify both run IDs appear and the item reads `- [x]`.

## 6. Integration check

- [ ] 6.1 **[edit]** Run `openspec validate adopt-drc-clean-defaults-and-requote --strict`. Open the results PR: `scripts/`, `docs/` and this change's directory only. The reference branch is not part of it and stays unmerged. Verify the fast lane is green.
