# Tasks

Tags:

- **[edit]** plain editing, checked with cheap local validation: actionlint, `openspec validate`, short OpenROAD calls in the `newt-eda:dev` image.
- **[eda]** loads a checkpoint in the image locally, minutes to an hour under emulation.
- **[long-run]** a P&R lane dispatch on the VM, about 9–12 h. Always ask the user first.

Local checkpoints live in the session scratchpad, or in `target/ihp13/openroad/out/ci-<run>/`, which is not committed. Fetch them from the `pnr-checkpoints` container the way `pnr.yml`'s "Download checkpoints from Blob" step does.

## 1. PDN channel-repair switch and connectivity gate (design D1–D3)

- [x] 1.1 **[eda]** Local gate on run `40081935481`'s checkpoints. Done 2026-11-16; the figures are in design.md's Context.
  - `pdn::allow_repair_channels 0` does not stop repair: still 10 partial-height straps. D1 was rewritten as removal after `pdngen`.
  - `check_power_grid -dont_require_terminals` works at this stage. Today's grid fails it (the west-edge hole, 14 reports per net). Removing the straps leaves both reports byte-identical. D2 was rewritten as a before/after comparison.
- [x] 1.2 **[edit]** Add `pnr_pdn_repair_channels` to `common.tcl` (`PNR_PDN_REPAIR_CHANNELS`: empty means 1, only `0` or `1`, an error naming the variable otherwise), commented like the other settings. In `power_grid_stripes.tcl`, after `pdngen`:
  - default to on when the variable is not defined (`chip.tcl`), and log `PDN channel repair: on|off`;
  - with repair off, run D2's before-checks, D1's removal (with its log line) and D2's after-checks and comparison, erroring before `save_checkpoint basilisk.power_grid` on a new report;
  - add D3's strap count in a `catch`, after any removal.

  Verify in the image on run A's checkpoints:
  - on `basilisk.power_grid` (the procs called directly, which skips the 15-minute `pdngen`): off removes 10 straps and 1,404 shapes, logs both nets `ok (14 pre-existing)`, and counts 0 straps afterwards;
  - the same with a floating shape injected between the checks: the stage errors and names it;
  - `2` fails before `pdngen`;
  - the `pdngen` call and everything before it are unchanged with the variable unset or `1` (diff of the script), and the count logs 10.
- [x] 1.3 **[edit]** Pass `PNR_PDN_REPAIR_CHANNELS` through `run_pnr.sh` (header doc block, next to `PNR_GRT_SRAM_METAL5_ADJUST`, noting that it acts only in `floorplan`). Document the setting, the log lines and the gate in `docs/pnr-pipeline.md`'s floorplan stage row. Verify that `run_pnr.sh` passes `bash -n`, and that the docs name the same variable and log lines as the code.

## 2. SRAM-end Metal5 hold-back (design D4)

- [x] 2.1 **[edit]** Add `pnr_grt_sram_end_metal5_adjust` to `common.tcl` (`PNR_GRT_SRAM_END_METAL5_ADJUST`, empty means 0, a number in [0, 1), an error naming the variable), and the constant `pnr_sram_end_strip_um` 40. In `pnr_apply_sram_metal5_adjustment`, return early only when both shares are 0. Add two 40 µm end strips inside each `RM_IHP*` footprint (along the long axis), and log `SRAM-end Metal5 adjustment: <v> over <n> strips (40 um)`. Verify in the image on run `40081935481`'s `grt` checkpoint (fetch it):
  - unset logs no end line, and issues the same region calls as today (32);
  - `0.5` logs 64 strips;
  - a second call in the process adds nothing;
  - `1` and `x` error before routing;
  - with the footprint share 0 and the end share 0.5, only the strips are added;
  - strip boxes for one R180 and one R90/R270 macro, printed and checked against the floorplan log's placements.
- [x] 2.2 **[edit]** Pass `PNR_GRT_SRAM_END_METAL5_ADJUST` through `run_pnr.sh`. Document it in `docs/pnr-pipeline.md` next to `sram_metal5_adjust`, with the strip width and how it stacks on the footprint share. Verify `bash -n` and that the docs match the code.

## 3. Dispatch inputs (design D5)

- [x] 3.1 **[edit]** Add the `pdn_repair_channels` and `sram_end_metal5_adjust` dispatch inputs to `pnr.yml`, empty by default, wired into the `pnr` step like `sram_metal5_adjust`. Update `docs/pnr-pipeline.md`'s input list and count (fourteen → sixteen), noting that `pdn_repair_channels` has no effect on a run resumed past `floorplan`. Verify:
  - actionlint is clean;
  - with both inputs empty, the rendered `pnr` command is identical to today's apart from two empty assignments;
  - the input list in the docs matches `pnr.yml`'s `inputs:` keys exactly.
- [x] 3.2 **[edit]** Verify `openspec validate clear-sram-corner-router-shorts --strict` passes. Open the PR with groups 1–3 and the change artifacts. After the user merges, the measured run dispatches on `main`.

## 4. Measured run (design D6)

- [x] 4.1 **[long-run]** *(ask the user first)* Dispatch on `main` with `pdn_repair_channels=0` and `sram_end_metal5_adjust=0.5`, everything else empty and no resume. Save `pnr-reports` under `target/ihp13/openroad/out/ci-<run>/`. Verify:
  - the floorplan log has `PDN channel repair: off`, 10 straps removed, 0 partial-height straps left, and both power-grid checks `ok` with the pre-existing count;
  - `grt.tcl` and `drt.tcl` log the SRAM-end adjustment over 64 strips;
  - `drt ok`, `final ok`, and the DEF artifact is published.
- [x] 4.2 **[edit]** Compare against run `40081935481` per D6:
  - the router count and the full marker list against A–D;
  - `grt` overflow (7,153);
  - WNS at `grt` (−12.05 ns);
  - antenna nets (8,627);
  - `drt` time.

  Record the comparison, the 2026-11-16 probe findings (the two mechanisms, the 10 repair straps and why repair cannot be turned off, why inter-row blocking was rejected, and the pre-existing west-edge PDN hole around the two Hyperbus delay lines as a follow-up) and D6's row in `docs/infra-plan.md`, after the 2026-10-30 record. Then ask the user before any follow-up dispatch.
- [ ] 4.3 **[long-run]** *(not run: 4.2 landed on the "WNS more than 1 ns worse" row, which names no resume; kept as a next candidate in `docs/infra-plan.md`)* *(only if 4.2 lands on a row that names a resume, or the user asks for the isolation run; ask first)* Dispatch the resume D6 names from the measured run's `cts`. Verify that `cts` and earlier were restored, and record the result as in 4.2.

## 5. Close-out

- [x] 5.1 **[edit]** Check that `docs/infra-plan.md` states the outcome and the next step: adopting both settings with a requote, a per-gap PDN strap change, or placement of the gap drivers. Verify `openspec validate clear-sram-corner-router-shorts --strict` passes.

## Workflow follow-up

- Archive the change once 5.1 is done and the user agrees. Sync the `pnr-flow` and `ci-pipeline` deltas.
