# Proposal

## Why

Run `39906592139` reached 8 detailed-routing violations, the first near-DRC-clean routed layout, but only through dispatch inputs:

- die scale 1.25;
- global-placement density 0.50;
- Metal2 hold-back 0.60;
- SRAM Metal5 hold-back 0.55;
- jumper-only antenna repair;
- a 28-iteration routing budget.

The lane's defaults are still the older settings: die 1.10, density 0.65, Metal2 0.30, no Metal5 hold-back, no antenna repair, 5 iterations. So every scheduled run still produces the layout that does not route.

The thesis P&R figures (`docs/results/sha3-ppa.md`, `docs/results/sha3-evaluation.md`) are also still quoted from the 1.10-die safety-net pair: runs `38395368038` (both arms) and `38772313345` (reference), at `grt` WNS −8.96 / −8.39 ns. `docs/infra-plan.md` names this as the next change (outcome of `drc-clean-sram-metal5-and-antenna`, 2026-10-23). The thesis figures should come from a layout that actually routes, and the settings should be lane defaults first, so that the figures and the scheduled runs share one configuration.

## What Changes

- **New lane defaults.** The flow's defaults become die scale 1.25, density 0.50, Metal2 hold-back 0.60 and SRAM Metal5 hold-back 0.55. The P&R lane's defaults become jumper-only antenna repair and a 28-iteration detailed-routing budget.
  - The 24 h `drt` timeout stays. 29 iterations took 7 h 04 m on run `39906592139`.
  - The local `drt.tcl` default mode also becomes jumper-only, since full repair hangs (run `39696194006`). Full repair stays available on request.
  - **BREAKING** for anyone resuming from a checkpoint made under the old defaults. A dispatch that resumes an old run without setting the inputs now mixes settings. The synth-key guard does not catch this, because the netlist is the same.
- **A way to turn antenna repair off.** Since repair now runs by default, `antenna_repair` gains a value that skips it.
- **Requote the thesis P&R figures from a fresh pair, both on the new defaults.**
  - **Both arms:** one input-less run on `main` after the defaults land. It also checks that the defaults reproduce the measured chain (`38931700180` → `39696194006` → `39906592139`). That chain spans three commits and dispatch inputs, so it cannot itself be the requote.
  - **Reference:** branch `pnr-reference-no-arms`, rebased onto that commit, runs with no inputs. No RTL has changed since its base (`52978e1`), so its netlist should equal synth run `38722761290`'s.
  - Both runs go through `final`, so both sides have a routed layout and an antenna count.
- **Report the routed outcome in the comparison.** For each run, the P&R section names the router's violation count and the antenna counts, next to the existing `grt` timing and power. Its flow sentence states the settings instead of the hard-coded `stop_after=grt`.
- **Regenerate and rewrite the results.**
  - `sha3_ppa.py` regenerates `sha3-ppa.md`.
  - `sha3-evaluation.md` carries the new figures.
  - The 1.10-die pair stays as a dated row under "earlier flow settings". It was legal, so it is not labelled superseded for illegality.
  - **The achieved period gets worse.** On the chain, `grt` WNS is −12.05 ns against −8.96 ns, so the period moves about 3 ns. That is the price of a routable layout, and the report says so.

Flow stages touched: **backend** (`common.tcl`, `drt.tcl`, `run_pnr.sh` defaults), **CI** (`pnr.yml` defaults and the antenna-repair values), **synth** and **backend** runs (one pair on the VM), plus docs and the report generator. RTL is touched only on the never-merged reference branch's rebase. No sim or sw change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `ci-pipeline`: in the P&R lane requirement, antenna repair runs jumper-only by default, a dispatch value skips it, and the routing defaults are the flow's new ones. The requirement no longer states that repair is skipped by default.
- `pnr-flow`: in "Global routing can hold back Metal5 over the SRAMs", the default share becomes 0.55 instead of zero.
- `sha3-evaluation`: in "SoC P&R comparison from legal, like-for-like placements", the report also names each run's detailed-routing outcome: router violations, antenna counts, and whether a routed design was produced.

## Impact

- **Code on `main`:**
  - `target/ihp13/openroad/scripts/pnr/common.tcl` (four defaults) and `drt.tcl` (default mode);
  - `target/ihp13/openroad/run_pnr.sh` (header);
  - `.github/workflows/pnr.yml` (input defaults and descriptions, antenna mapping, its check step);
  - `docs/pnr-pipeline.md`;
  - `scripts/sha3_ppa.py`;
  - `docs/results/sha3-ppa.md` (regenerated) and `docs/results/sha3-evaluation.md`;
  - `docs/infra-plan.md`.
- **Reference branch only:** rebase `pnr-reference-no-arms` onto the new `main`. Its four-file diff stays.
- **Scheduled runs:** every weekly run now places on the 1.25 die, routes 28 iterations with jumper repair, and should publish a near-clean DEF in about 16 h. Old checkpoints are not resumable without the old inputs.
- **Compute:** two full P&R runs of about 16 h each, about $40 on the VM. The reference branch also needs one synthesis if the VM-local cache misses, about 2.5 h. Each dispatch is asked first.
- **Thesis numbers:** WNS, achieved period and every energy-per-byte figure at that period move, along with power at `grt`. The SoC synthesis and block-level figures do not.
