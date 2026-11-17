# Tasks

Tags:

- **[edit]** plain editing, checked with cheap local validation: `openspec validate`, short OpenROAD calls in the `newt-eda:dev` image.
- **[eda]** loads a checkpoint in the image locally, minutes under emulation.
- **[long-run]** a P&R lane dispatch on the VM, about 12 h. Always ask the user first.

The local checkpoint is run `40081935481`'s `basilisk.power_grid.zip`. It is in the session scratchpad, or can be fetched from the `pnr-checkpoints` container the way `pnr.yml`'s "Download checkpoints from Blob" step does. The probe harness from the proposal (load the checkpoint, call the procs directly, which skips the 15-minute `pdngen`) is the model for the verifications below.

## 1. Delay-line rail bridges (design D1, D2, D4)

- [x] 1.1 **[eda]** Add `scripts/pdn_delay_line_rails.tcl` (SHL-0.51 header, newt copyright line as in `pdn_repair_straps.tcl`) with `pdn_bridge_delay_line_rails`:
  - finds every `delay_line_D4_O1_6P000` instance;
  - fails on a non-R0 orientation;
  - adds abutting Metal1 `FOLLOWPIN` boxes per D1 and logs `Delay-line rail bridges: <n>`;
  - errors per D2, naming the instance and the rail, when a supply pin rail has no same-net rail within 1 µm on either side.

  Source it and call it in `power_grid_stripes.tcl` right after `pdngen`. Verify in the image on the local checkpoint:
  - the call logs 48 bridges, all 0.44 µm wide at x 387.72–388.16 and 428.0–428.44 µm;
  - a second checkpoint load with one core rail's end box deleted first still bridges that pin from the other side;
  - with both sides of one pin deleted, the call errors and names the instance;
  - a design without delay lines (the proc called with a master name that has no instances; the master is a proc argument for this) logs 0 and passes.

  Done 2026-11-17 on run `40081935481`'s `basilisk.power_grid`:
  - 48 bridges, x-spans exactly 387.72–388.16 and 428.0–428.44 µm;
  - with the west rail of the rx macro's 4097.30 µm VDD pin deleted, 47 bridges and no error;
  - with both sides deleted, it errors with "Delay line …i_delay_rx_rwds_90… VDD rail at y 4097.3-4097.74 um: no VDD Metal1 rail within 1.0 um on either side" and creates no boxes;
  - an unknown master logs 0.

## 2. Always-on grid check (design D3)

- [x] 2.1 **[eda]** Add `pdn_check_grid` next to `pdn_check_net` in `pdn_repair_straps.tcl`: run both nets with tag `final`, log `Power grid check <net>: clean` or `failed (<n> reports)` plus each entry, and error if either failed. Call it in `power_grid_stripes.tcl` after the strap count, before the stripe blockages, per D3's order. Verify in the image on the local checkpoint:
  - after the bridges, both nets log `clean` and the two `_final.rpt` files are absent or empty;
  - without the bridges, the call fails with 14 reports per net (the hole as recorded in `docs/infra-plan.md`);
  - with repair off and the bridges, the removal gate logs `ok (0 pre-existing)` on both nets, then the final check is clean.

  Done 2026-11-17, same checkpoint:
  - with the bridges: `Power grid check VDD: clean` and the same for VSS, with no `_final.rpt` written;
  - without them: `failed (14 reports)` on each net, the error "Unconnected supply shapes on: VDD VSS", and 14 entries in each `_final.rpt`;
  - repair off: 10 straps and 1,404 shapes removed, both gates `ok (0 pre-existing)`, then both final checks clean.
- [x] 2.2 **[edit]** Document the bridges, the final check, their log lines and report files in `docs/pnr-pipeline.md`'s floorplan stage row. Note that a run resumed past `floorplan` keeps its checkpoint's grid. Verify that the docs name the same log lines and file names as the code, and that `git diff` shows no change to the `pdngen` call or anything before it in `power_grid_stripes.tcl`.
- [x] 2.3 **[edit]** Verify `openspec validate fix-delay-line-power-rails --strict` passes. Open the PR with groups 1–2 and the change artifacts. After the user merges, the measured run dispatches on `main`.

## 3. Measured run (design D5)

- [ ] 3.1 **[long-run]** *(ask the user first)* Dispatch the P&R lane on `main` with every input empty and no resume. Save `pnr-reports` under `target/ihp13/openroad/out/ci-<run>/`. Verify:
  - the floorplan log has `Delay-line rail bridges: 48` and both `Power grid check <net>: clean` lines;
  - `drt ok` and `final ok`;
  - the final DEF has the 48 bridge boxes in `SPECIALNETS`.
- [ ] 3.2 **[edit]** Compare against run `40081935481` (run A) per D5:
  - router markers in the bridge window (expected none);
  - the full marker list, `grt` overflow (7,153), WNS at `grt` (−12.05 ns), antenna nets (8,627) and `drt` time, against run A;
  - also, informationally, against `43937159728`.

  Record the hole's mechanism, the fix, the probe and the comparison in `docs/infra-plan.md` as a dated record after 2026-11-17's, and mark that record's "PDN hole (not fixed)" bullet as fixed with a pointer. If markers sit on the bridges, apply D5's fallback (west side only) in a follow-up commit and ask the user before re-running.

## Workflow follow-up

- Archive the change once 3.2 is recorded and the user agrees. Sync the `pnr-flow` delta.
