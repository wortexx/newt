# Tasks

Tags:
- **[edit]** Plain editing, checked with cheap local validation: `bash -n`, shellcheck, `openspec validate`, a stub-`openroad` harness for `run_pnr.sh`'s control flow.
- **[eda]** Loads a checkpoint in the `newt-eda:dev` image locally, minutes to hours under emulation. Run one at a time; Docker has 19.5 GB.
- **[long-run]** A P&R dispatch on the VM. Always ask the user first.

Prerequisite: `finish-antenna-diode-repair` is merged (the `ant` stage), and run A (`40081935481`) still has its checkpoints in storage.

## 1. Confirm the hypothesis locally (design D3)

- [x] 1.1 **[eda]** On run A's `grt_repaired` (`target/ihp13/openroad/out/local-ant/save/`, or download it again), in one OpenROAD process, run in order:
  1. `repair_antennas -jumper_only`;
  2. `pnr_detailed_placement -incremental`;
  3. `grt::set_verbose 1`;
  4. `repair_antennas -diode_only -allow_congestion`, timed with `clock seconds`, with an 8 h wall-clock limit.

  First check that `grt::set_verbose` exists in the image (`info commands grt::set_verbose`). Record in design D3:
  - whether the call returned;
  - the `GRT-0009` net count;
  - the time from `GRT-0015` to return;
  - any `GRT-0232`.

  If it returns with `GRT-0232`, stop and report: D4's last row.

## 2. The flag and its reporting (design D1, D2)

- [x] 2.1 **[edit]** In `ant.tcl`'s full mode:
  - before the diode call, log `Diode reroute: congestion allowed` and call `grt::set_verbose 1`;
  - pass `-allow_congestion` to `repair_antennas -diode_only`;
  - time the call and log `Diode step: <s> s (congestion allowed)`;
  - update the header comment with the overflow-loop finding and run `40399844770`.

  The jumper call stays unchanged. Verify `git diff` touches only the full-mode branch and the header, and that a stub run of `ant.tcl` in jumper mode (as in `finish-antenna-diode-repair` 2.1) still logs `ant ok antenna=jumper` with no `Diode` lines. *(A stub run loads a checkpoint, so this is [eda]: run it alone.)*
- [x] 2.2 **[edit]** In `run_pnr.sh`'s `report_ant_outcome`:
  - add `rerouted=<n>`: the last `GRT-0009` after `Antenna repair: diodes`, empty if none;
  - add `diode_s=<s>`: from the `Diode step:` line, empty if absent;
  - print a `::warning::` when `GRT-0232` appears after the marker.

  Verify on fixture logs:
  - a completed diode step (both fields set);
  - a timed-out one (`rerouted` set, `diode_s` empty);
  - one with `GRT-0232` (the warning fires);
  - a jumper-only log (row unchanged from today).

  `bash -n` and shellcheck (`-S warning`) are clean.
- [x] 2.3 **[edit]** Update `docs/pnr-pipeline.md`: the `ant` stage row (the flag and why) and the `ant-repair` report paragraph (the two new fields). In `docs/infra-plan.md`, change run `40399844770`'s "Next candidate: post-route repair" to point to this change, and say why: post-route repair reaches the same reroute. Verify with `grep -n "allow_congestion\|rerouted=\|diode_s=" docs/pnr-pipeline.md`.
- [x] 2.4 **[edit]** Open the PR with groups 1–2 and this change's artifacts. Verify `openspec validate allow-congestion-in-diode-repair --strict` passes and the fast lane is green.

## 3. Measured run (design D4)

- [ ] 3.1 **[long-run]** *(ask the user first)* Dispatch from run A: `resume_from_run=40081935481`, `resume_exclude=drt final`, `antenna_repair=1`. Save its `pnr-reports` under `target/ihp13/openroad/out/ci-<run>/`. Verify:
  - stages through `grt_repair` were restored;
  - an `ant` row and an `ant-repair` row with `rerouted=` and `diode_s=`;
  - `drt` ran on `ant` or `ant_jumper` as recorded;
  - a `drt-antenna` row;
  - `final ok` with the DEF.
- [ ] 3.2 **[edit]** Compare with run A per D4: antenna nets / pins, the router count after iteration 28, the `ant` time, diodes, and rerouted nets. Pick D4's row and record both in `docs/infra-plan.md`, with the next step. Ask the user before any follow-up dispatch or default change. Verify `openspec validate allow-congestion-in-diode-repair --strict` passes.
