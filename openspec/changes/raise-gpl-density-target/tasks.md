# Raise the global-placement density target — tasks

Tags:

- **[edit]**: plain file editing, checked locally (`bash -n`, `shellcheck`, the driver's
  `PNR_DRY_RUN=1` mode).
- **[long-run]**: a P&R lane run on the self-hosted Azure VM (≥ 6 h resumed, ≥ 10 h full). Each
  one is dispatched **only after the user approves it**, never as a speculative check.

## 1. Density target, in one place

- [x] 1.1 **[edit]** Define the density once in `target/ihp13/openroad/scripts/pnr/common.tcl` as
  `pnr_gpl_density`: the value of `PNR_GPL_DENSITY` when set, else `0.72` (design D1). Use it in
  both `GPL_ARGS` and `GPL2_ARGS` in `scripts/pnr/gpl.tcl`, and have `gpl.tcl` log the effective
  value with `utl::report`. Verify that `grep -n "density" scripts/pnr/gpl.tcl` shows no
  literal `0.65`, and that the only literal default is the one in `common.tcl`.
- [x] 1.2 **[edit]** Set the same `0.72` in `scripts/chip.tcl`'s `GPL_ARGS` and `GPL2_ARGS`,
  with a comment pointing to `scripts/pnr/common.tcl` as the value the CI lane uses. Verify that
  `grep -rn "density 0.65" target/ihp13/openroad/scripts/` returns nothing.
- [ ] 1.3 **[edit]** Add an optional `workflow_dispatch` input, `gpl_density`, to `pnr.yml`. Pass
  it to the `pnr` job as `PNR_GPL_DENSITY` (empty means the default), next to `stop_after`, and
  document it in `docs/pnr-pipeline.md`'s input list. Verify the workflow parses (`gh workflow
  view pnr.yml` lists the input after push) and that `run_pnr.sh`'s header lists the variable.

## 2. Headroom warning

- [x] 2.1 **[edit]** In `run_pnr.sh`, after the `dpl` stage, read `DPL-0009` "Utilization" from
  `pnr_dpl.log` and the effective density (D1). Print both on one line. Emit
  `::warning::` naming both when utilization ≥ target, and say that `DPL-0009` is (movable +
  fixed) / core, used as a proxy (design D2). Do not change the exit status. Verify against two
  fixture logs: the 09-15 run's `pnr_dpl.log` (62.9 %, no warning at 0.65) and the 09-26 run's
  (66.1 %, warning at 0.65, none at 0.72). Also verify `bash -n run_pnr.sh`, `shellcheck`
  showing no new findings, and `PNR_DRY_RUN=1` still listing every stage.
- [x] 2.2 **[edit]** Add the headroom line to the `pnr-flow` behaviour described in
  `docs/pnr-pipeline.md` (what it prints, when it warns, that it never fails a run). Verify the
  section names `DPL-0009` and `PNR_GPL_DENSITY`.

## 3. Measure: resumed run (density check)

- [x] 3.1 **[edit]** Find a surviving `pre_place` checkpoint of a run on the current
  pre-coprocessor netlist. That means the `pnr-export` storage of run `36188933699` or any later
  run on the same synth-cache key, checked through the lane's restore job, or listed with `az
  storage blob list` per `infra/azure/README.md`. Record the run id, or record that none exists,
  in which case group 3 merges into group 4. Verify by the listing output. — done: **none exists**, so group 3 merges into group 4 (design D3). The last P&R run of any kind is `36188933699` (2026-09-25, `599d837`). The Cheshire v0.3.1 bump (#48, 2026-09-27) changed the netlist, and no P&R run has started since (`gh run list --workflow pnr.yml`). So no checkpoint matches the current synth key, and the lane's synth-key identity guard refuses a mismatched one. The blob listing itself was not possible: the local account has no Storage Blob data role on `newtpnrcheckpoints`, by design.
- [ ] 3.2 **[long-run]** Ask the user, then dispatch `pnr.yml` on this change's branch with
  `resume_from_run=<3.1>`, `resume_exclude` covering `gpl` and every later checkpoint, and
  `stop_after=cts`. Verify the run reaches `cts ok` in its status log. Record in
  `docs/infra-plan.md` Phase 11, next to run `34938462965`: `DPL-0009` utilization, illegal cells at
  legalizer iteration 0, `dpl`/`cts` runtimes, and HPWL after `dpl` and `cts`. If `dpl` or `cts`
  still times out, stop and report to the user before changing anything else.

## 4. Merge and the clean reference

- [ ] 4.1 **[edit]** Update `docs/infra-plan.md` Phase 11: tick the density action with the
  group 3 result, and record that P&R figures from before this change are not comparable with
  figures from after it. Verify the Phase 11 text names the new default and the
  `PNR_GPL_DENSITY` override.
- [ ] 4.2 **[long-run]** After merge, ask the user, then dispatch a fresh full `pnr.yml` run on
  `main` (no resume). Verify the status log reaches `grt ok` within the default stage timeouts,
  with no headroom warning. Record in Phase 11: the stage reached; WNS and power at the latest
  stage reached; `grt` total demand and Metal3, against 101.17 % / 115.27 %; and the
  `drt` outcome as best-effort. Record it as the reference for `sha3-cvxif-coprocessor` task 5.4.
- [ ] 4.3 **[edit]** Decision point (design D4): if 4.2's `grt` congestion exceeds the 09-15
  figures by more than 5 points, or `grt` fails, report to the user with the numbers and the
  timeout-only fallback (keep 0.65; `dpl` 14400 s, `cts` 28800 s). Do not switch on your own.
  Verify that either Phase 11 records "within 5 points", or the user's decision is recorded.
