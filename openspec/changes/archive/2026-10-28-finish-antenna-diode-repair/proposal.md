# Proposal

## Why

Jumper-only antenna repair leaves **8,627 nets / 11,287 pins** violating on the near-clean layout (run `39906592139`). That is 74 % of the unrepaired count. Jumpers move charge collection upward but cannot fix gate-side ratios, which needs diodes.

Full repair, jumpers then diodes, has now hung twice. In run `34389061373`, at 101 % routing demand, and in run `39696194006`, at 46 % utilization, it ate `drt`'s whole 24 h budget and left no routed design. In the second run, 18,902 diodes were inserted, the following legalization stopped with 9,663 violations, and the stage then logged nothing for about 23 h.

OpenROAD's source (`2c56926971`) shows why. After inserting diodes, `repair_antennas` re-legalizes **the whole design** non-incrementally (`opendp_->detailedPlacement(0, 0, "")`). It does so with the negotiation legalizer unless diamond was already selected in the same process. Then it globally reroutes every net whose cells moved. A non-converging legalization of about 996 k cells moves a large share of them, and the reroute runs single-threaded.

So diode repair needs two things before it can be a default: a hang must not cost the routed design, and the legalization must move fewer cells.

This change follows `adopt-drc-clean-defaults-and-requote`. It assumes jumper-only repair is already the default and measures from that change's input-less run.

## What Changes

- **Antenna repair becomes its own bounded stage.** A new stage `ant` sits between `grt_repair` and `drt`, so repair runs in its own OpenROAD process with its own timeout.
  - It first runs jumper insertion and saves a checkpoint.
  - It then runs diode insertion and saves a second checkpoint.
  - `drt` loads the newest of the two and no longer repairs antennas itself.
  - If diode insertion fails or times out, `drt` routes the jumper-repaired design, and the status says which result was routed. A hang now costs the `ant` timeout, not the routed design.
- **Diode legalization uses the flow's diamond legalizer.** Before diode insertion, the stage makes one incremental diamond `detailed_placement` call on the already-legal design. OpenROAD's legalizer choice is sticky within a process (`use_diamond_legalizer_ |= …`), so `repair_antennas`' internal re-legalization then uses diamond too. The stage log records which legalizer placed the diodes.
- **The repair mode's meaning is unchanged.** `jumper` stops after the first checkpoint, `full` runs both steps, and `skip` runs neither. Jumper-only stays the default until the measured run says otherwise.
- **One measured run.** From the `grt` checkpoint of the requote's both-arms run, run `ant` in full mode, then `drt` and `final`. Compare:
  - antenna nets / pins, against 8,627 / 11,287;
  - the router count, against that run's own;
  - `ant` run time, diodes inserted, and legalization violations left;
  - WNS at `drt` entry.

  Record the result in `docs/infra-plan.md`, and whether full repair should become the default.
- If diamond does not stop the hang, the fallbacks are named in design.md and are not built here: post-route repair with a detailed-routing ECO pass, or `-ratio_margin` for residual marginal nets.

Flow stages touched: **backend** (a new `ant.tcl`, `drt.tcl`, `run_pnr.sh`'s stage list and timeouts) and **CI** (`pnr.yml`'s timeout, summary, checkpoint names in docs). No RTL, sim, synth or sw change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pnr-flow`: new requirement "Antenna repair is bounded and never costs the routed design". Antenna repair runs as its own stage with its own timeout and an intermediate jumper-repaired result. A diode-insertion failure or timeout falls back to that result for detailed routing, and the status names which result was routed. Diode legalization uses the flow's selected legalizer.

`ci-pipeline` is deliberately not modified. Its P&R lane requirement already says antenna repair stays best-effort whether it completes, fails or times out. `adopt-drc-clean-defaults-and-requote` also modifies that same requirement, and a second delta on it would overwrite the first when archived.

## Impact

- **Code:**
  - `target/ihp13/openroad/scripts/pnr/ant.tcl` (new);
  - `drt.tcl` (loads `ant`/`ant_jumper` and drops its own repair);
  - `common.tcl` (if a shared helper is needed);
  - `target/ihp13/openroad/run_pnr.sh` (stage list, checkpoint names, the fallback, `report_*`);
  - `.github/workflows/pnr.yml` (`ant` timeout, summary, `resume_exclude` names in descriptions);
  - `docs/pnr-pipeline.md`;
  - `docs/infra-plan.md`.
- **Checkpoints:** two new names, `ant_jumper` and `ant`. Resuming a run made before this change from `grt_repaired` still works, because `ant` simply runs.
- **Scheduled runs:** with jumper-only as the default, `ant` adds one process start and a checkpoint save, a few minutes.
- **Compute:** one resumed run from `grt` (`ant` + `drt` + `final`), about 8–12 h on the VM. Asked first.
- **Thesis numbers:** none, unless a follow-up adopts full repair as the default and the requote is refreshed.
