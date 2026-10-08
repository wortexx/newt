## Why

The thesis quotes an "achieved period" of 19.23 ns (11.0 ns constraint minus WNS −8.23 ns after
`grt`, run `37162759719`), and the energy figures use it. That WNS is measured with post-route
timing repair turned off: `pnr.yml` hardcodes `PNR_SKIP_GRT_REPAIR=1`. After `cts` the same run is
at −2.70 ns. The jump to −8.23 ns comes from switching to global-route parasitics with nothing
repairing afterwards. So the coprocessor's *delta* (−8.36 → −8.23 ns) holds, but the *absolute*
period is a flow artefact presented as if it were the SoC's speed.

`grt_repair` was skipped on 2026-09-13 for reasons that no longer hold. Then the design routed at
101 % demand (Metal3 115 %), `grt` alone took ~9 h, WNS was −14.76 ns, and the stage hit a 16 h
ceiling. Since `raise-gpl-density-target`, demand is 77–84 % (Metal3 95–109 %) and `grt` takes
~3 h 10 m, so the stage's three global routes plus repair should plausibly fit in 16 h. It has not
been run since.

Both runs' `grt` checkpoints are in Blob storage, which expires them 30 days after upload
(`checkpointRetentionDays = 30`): around 2026-11-02 for the reference and 2026-11-03 for the
coprocessor run. Resuming from them costs one stage. After they expire, it costs a full ~15 h flow
per run first.

This also settles Phase 11's open framing question. The `sha3-evaluation` spec's quotable stages
end at post-global-route, and the `pnr-flow` spec makes detailed routing best-effort, so the
thesis does not need a detail-routed DEF. The open routability levers become future work.

## What Changes

- **CI**: a `workflow_dispatch` input on `pnr.yml`, `skip_grt_repair`, plumbed to
  `PNR_SKIP_GRT_REPAIR`. Empty means `1`, today's behaviour, so scheduled, tag and input-less runs
  are unchanged. `0` runs `grt_repair.tcl`'s bounded repair as written
  (`-repair_tns 20 -max_buffer_percent 15`), within the existing 16 h stage timeout.
- **Backend measurement**: two resume dispatches, each from a measurement branch cut at the
  original run's source commit (`dff4df0` for reference run `37108127061`, `4c25003` for the run
  with both arms, `37162759719`) carrying only the workflow change, so the netlist-identity guard
  matches. Both use `resume_exclude=grt_repaired stop_after=grt_repair skip_grt_repair=0`.
  `main` cannot be used for the second one: testbench edits under `hw/` since `4c25003` change
  the synth cache key.
- **Results**: WNS/TNS, area, buffer count and runtime after `grt_repair` for both runs, compared
  with `grt`. If repair converges, the achieved period and the energy figures that depend on it are
  requoted from it. If the stage times out or fails, that is recorded as the result, and the
  existing figure is reworded as "after global route, before post-route repair".
- **Report generator**: `scripts/sha3_ppa.py`, which writes `docs/results/sha3-ppa.md`, learns
  to read a repair run's `pnr-reports` for each side. It quotes WNS/TNS after `grt_repair` when
  both sides' repair completed, takes the achieved period from there, and otherwise labels the
  `grt` figures and the achieved period as "before post-route repair".
- **Docs**: `docs/infra-plan.md` Phase 11 records the framing decision and moves the routability
  levers to future work; section 0's WNS caveat and Phase 5's "repair bounding" note are updated
  with the measured outcome. `docs/results/sha3-ppa.md` and `docs/results/sha3-evaluation.md` say
  whether each timing figure comes from before or after post-route repair.

Flow stages touched: **CI** (`pnr.yml`), **backend** (a measurement only, no flow-script change)
and the results tooling (`scripts/sha3_ppa.py`). No RTL, sim, synth or sw change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `ci-pipeline`: the P&R lane's manual-dispatch requirement lists the inputs it accepts. It still
  names three, although `gpl_density`, `gpl_keep_resize` and `die_scale` were added since. It gains
  `skip_grt_repair` and states that empty placement and repair inputs keep the defaults.
- `sha3-evaluation`: a timing figure taken at global route states whether post-route repair ran,
  and an achieved period derived from a WNS states the same.

## Impact

- **Code**: `.github/workflows/pnr.yml` (one input, one env value) and `scripts/sha3_ppa.py`
  (repair-run parsing and labels). `grt_repair.tcl`, `run_pnr.sh` and the stage timeouts are
  unchanged.
- **Branches**: two short-lived measurement branches, kept until the results are recorded. They
  are never merged.
- **Cost**: two P&R dispatches, each restoring checkpoints and then running only `grt_repair`,
  estimated at 10–16 h ≈ $12–20 each at $1.216/h. Each is dispatched only after the user approves
  it, and both before 2026-11-02.
- **Results at risk**: none of the already-measured figures change unless repair converges. The
  coprocessor-vs-reference comparison stays on the same settings: both runs, or neither, get
  repair.
- **Not changed**: the `grt` gate, routing-layer adjustments, congestion iterations, antenna
  repair, `drt`, the die, and the scheduled lane's behaviour.
