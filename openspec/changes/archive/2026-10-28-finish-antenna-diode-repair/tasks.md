# Tasks

Tags:
- **[edit]** Plain editing, checked with cheap local validation: `bash -n`, actionlint, `openspec validate`, a stub-`openroad` harness for `run_pnr.sh`'s control flow.
- **[eda]** Loads a checkpoint in the `newt-eda:dev` image locally, minutes to hours under emulation. Run one at a time; Docker has 19.5 GB.
- **[long-run]** A P&R dispatch on the VM. Always ask the user first.

Prerequisite: `adopt-drc-clean-defaults-and-requote` has merged its defaults, and its input-less both-arms run A exists.

## 1. Confirm the diamond lever locally (design D2)

- [x] 1.1 **[eda]** On a `grt` checkpoint with the new defaults, in one OpenROAD process:
  1. dump every instance's location;
  2. call `pnr_detailed_placement -incremental`;
  3. dump again and compare;
  4. run `repair_antennas -jumper_only` and then `repair_antennas -diode_only`, with a local wall-clock limit of 4 h.

  Use A's checkpoint, or `39696194006`'s if A does not exist yet. Verify:
  - no instance moved in the incremental call;
  - the DPL lines inside `repair_antennas` show the diamond search and no `DPL-1102 … negotiation`.

  Record the diode count, the legalization time, and whether the reroute finished within the limit, in design D2. If negotiation still appears, stop and report (D5's fourth row).

## 2. The `ant` stage (design D1, D3)

- [x] 2.1 **[edit]** Add `scripts/pnr/ant.tcl` (SPDX header, header comment in the style of `drt.tcl`) implementing D1's steps for `skip`, `jumper` and `full`, with D2's diamond call and log line. Its status detail is `antenna=<mode>`. Move the mode parsing and validation from `drt.tcl` into it. Verify in the image on a `grt_repaired` checkpoint:
  - `skip` saves `ant` and reports `ant ok antenna=skipped`;
  - `jumper` saves `ant_jumper` and `ant`;
  - an unknown mode fails before loading.

  Leave `full` to 1.1's evidence and 4.1.
- [x] 2.2 **[edit]** In `drt.tcl`, load `ant` if its zip exists, else `ant_jumper`, and drop the `repair_antennas` call. The status detail records `input=<checkpoint>`. Update the header comment. Verify on a stub run (`detailed_route` stubbed) that both load paths log the right checkpoint, and that `check_antennas` still runs.
- [x] 2.3 **[edit]** In `run_pnr.sh`:
  - add `ant` to `STAGES` with checkpoint `ant`, 0 retries and a 4 h default timeout;
  - implement the `fallback=ant_jumper` rule;
  - add `report_ant_outcome` (D3);
  - update the header.

  Verify with a stub `openroad` on `PATH` that writes the expected zips or exits as told:
  - `ant` ok → `drt` runs;
  - `ant` times out with `ant_jumper.zip` present → `ant failed … fallback=ant_jumper` and `drt` runs;
  - `ant` fails without it → `drt skipped predecessor-failed`;
  - the exit status still follows the `grt` gate;
  - `report_ant_outcome` parses a fixture log with GRT-0302 / GRT-0015 / DPL-0701 lines, and gives `none` without them;
  - `bash -n` is clean.
- [x] 2.4 **[edit]** In `pnr.yml`:
  - set `PNR_TIMEOUT_ANT=14400`;
  - add `ant_jumper` and `ant` to the `resume_exclude` description;
  - print the `ant-repair` row (it comes through the status table).

  Update `docs/pnr-pipeline.md`: the stage table row for `ant`, the `drt` row, the checkpoint list, and the reports section. Verify actionlint 1.7.10 is clean and the rendered `pnr` command differs from today's only by `PNR_TIMEOUT_ANT=14400`.
- [x] 2.5 **[edit]** Open the PR with groups 1–2 and this change's artifacts. Verify `openspec validate finish-antenna-diode-repair --strict` passes and the fast lane is green.

## 3. Defaults stay

- [x] 3.1 **[edit]** Confirm that with no inputs a run still means jumper-only: the `ant` stage's mode default is `jumper`, and the lane's empty `antenna_repair` maps to it. Verify by rendering the `pnr` command with empty inputs, and on 2.1's `jumper` check.

## 4. Measured run (design D4, D5)

- [x] 4.1 **[long-run]** *(ask the user first)* Dispatch from run A's `grt` with `resume_exclude=drt final` and `antenna_repair=1`. Save its `pnr-reports` under `target/ihp13/openroad/out/ci-<run>/`. Verify:
  - stages through `grt_repair` restored;
  - an `ant` row and an `ant-repair` row;
  - `drt` ran on `ant` or `ant_jumper` as recorded;
  - a `drt-antenna` row;
  - `final ok` with the DEF.
- [x] 4.2 **[edit]** Compare with run A per D4, pick D5's row, and record both in `docs/infra-plan.md`. Ask the user before any follow-up dispatch or default change.

## 5. Close-out

- [x] 5.1 **[edit]** Check that `docs/infra-plan.md` states the outcome and the next step. Verify `openspec validate finish-antenna-diode-repair --strict` passes.
