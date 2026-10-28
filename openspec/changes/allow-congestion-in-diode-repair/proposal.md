# Proposal

## Why

Full antenna repair has never finished on this layout. On run `40399844770`, change `finish-antenna-diode-repair` showed that diode placement is no longer the problem: diamond legalization placed the 18,902 diodes in 10.5 s. The `ant` stage then logged nothing for 3 h 52 m until its 4 h timeout. The OpenROAD source (`2c56926971`) points to the cause.

- `ant.tcl` calls `repair_antennas -diode_only` without `-allow_congestion`.
- The diode step's incremental global reroute then runs with congestion not allowed. Run A's global route already has 7,153 overflow.
- Whenever any overflow remains, that reroute tries to clear it: up to 31 rounds, each rerouting every net that crosses an overflowed gcell, plus a full re-legalization in the last round. If overflow still remains, it raises `GRT-0232` ("Routing congestion too high").
- The flow's own global routing passes `-allow_congestion` (`grt.tcl`, `grt_repair.tcl`) for exactly this reason. Without the flag, diode repair cannot succeed on this layout: it either runs for hours or fails at the end.

The recorded next candidate, post-route repair, goes through the same reroute, so it would hang the same way. The flag is the cheaper test, and it comes first.

## What Changes

- **Backend:**
  - `ant.tcl`'s diode step passes `-allow_congestion` to `repair_antennas -diode_only`, so the reroute accepts the global route's existing overflow, as `global_route` does in `grt.tcl`.
  - The jumper step is unchanged: on this build, jumper insertion with FastRoute does no reroute.
  - The stage logs that congestion is allowed.
- **Backend reporting:**
  - `ant.tcl` logs how long the diode step took: insertion, legalization and reroute together.
  - `run_pnr.sh`'s `ant-repair` row repeats that duration.
- **CI:** none. `antenna_repair=1` already selects full repair, and the default stays jumper-only.
- **Docs:**
  - `docs/pnr-pipeline.md` describes the flag.
  - `docs/infra-plan.md` replaces "next candidate: post-route repair" with this change and records its measured run.
- **Measured run:** one dispatch from run A (`40081935481`) with `antenna_repair=1`, inside `ant`'s existing 4 h bound. Its result decides whether full repair can become the default; that decision is a follow-up change.

No RTL, sim, synth or sw stage is touched.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pnr-flow`: the requirement *Antenna repair is bounded and never costs the routed design* gains a rule: diode insertion's reroute accepts the global route's existing congestion instead of trying to clear it, and the stage log says so.

## Impact

- **Code:** `target/ihp13/openroad/scripts/pnr/ant.tcl` (one flag, the log line and the header comment) and `target/ihp13/openroad/run_pnr.sh` (`report_ant_outcome`).
- **Docs:** `docs/pnr-pipeline.md`, `docs/infra-plan.md`.
- **Runs:**
  - Scheduled runs are unchanged, because jumper-only never reaches the diode step.
  - A full-repair dispatch keeps its 4 h bound and its `ant_jumper` fallback.
  - With overflow allowed, the diode reroute may leave guides through congested gcells. Detailed routing already starts from such a global route, since `grt` allows congestion too.
- **Cost:** one local probe under emulation, and one VM run of about 12 h (ask first).
