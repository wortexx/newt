## Context

The P&R lane (`.github/workflows/pnr.yml`) runs the staged driver `target/ihp13/openroad/run_pnr.sh`.
Each stage is an OpenROAD script under `scripts/pnr/` with its own wall-clock timeout
(`STAGE_TIMEOUT_DEFAULT`: `dpl` 7200 s, `cts` 14400 s) and its own checkpoint. `gpl.tcl` runs two
global-placement passes. Between them, `repair_design` and `repair_timing` add the buffers that
take utilization from the netlist's own ~57 % (`pre_place` "Design area") to the 66.1 % that
`dpl` measures. Both passes set `-density 0.65`. The monolithic `scripts/chip.tcl`, which the
staged scripts were adapted from (`ci-pnr-lane` D1), carries the same values. The diagnosis
behind this change is in `docs/infra-plan.md` Phase 11 (2026-10-02); see proposal.md for the
numbers.

The lane already supports cheap partial runs. `resume_from_run` restores another run's
checkpoints (stages with a restored checkpoint are skipped), `resume_exclude` drops named
checkpoints so their stages re-run, and `stop_after` ends the driver after a named stage. The
synth cache on the VM skips resynthesis when the netlist inputs are unchanged.

## Goals / Non-Goals

**Goals:**

- `dpl` and `cts` legalize from a near-legal placement again, within the existing timeouts, on
  the current netlist and on the SHA-3 coprocessor's netlist.
- A clean pre-coprocessor P&R reference on `main` (the stage reached, WNS and power), on the same
  settings the coprocessor run will use.
- A design that outgrows its density target is named in the run output.

**Non-Goals:**

- Detailed-route convergence (Phase 11's `drt` blocker, which is congestion) stays best-effort,
  as `pnr-flow` already specifies.
- Timing closure.
- Tuning `gpl`'s routability or timing-driven knobs beyond the density value.
- Changing the floorplan, die or core area.

## Decisions

### D1 — Target density 0.72, in one place

The density becomes a single variable, defined once in `scripts/pnr/common.tcl` with default
`0.72`. Both `gpl` passes use it, and the environment variable `PNR_GPL_DENSITY` can override it.
`chip.tcl` gets the same default.

- **Why 0.72.** The current design enters `dpl` at 66.1 %, and the coprocessor's netlist is
  estimated at ~69.5 %. 0.72 leaves about 2.5 points over the larger one. That covers the
  estimate's error (it scales area linearly, but repair-buffer growth is not linear) without
  going far past the need.
- **Why not 0.70.** It sits inside the coprocessor's estimate error, so it fixes `main` and
  could fail the measurement this change exists for.
- **Why not 0.75 or more.** Density above the need packs cells tighter than necessary, which
  costs routing congestion (Phase 11: Metal3 already at 115 %) for no legalization gain.
- **Why an override.** Each P&R run costs ≥ 10 h, so a second value must not need a commit. An
  optional `pnr.yml` `workflow_dispatch` input, `gpl_density`, passes the override through
  (empty means the default).

**Comparing the two numbers.** `DPL-0009` "Utilization" is (movable + fixed area) / core area. The
`gpl` target density applies per bin to the space macros leave free, so the two are not the same
quantity. The diagnosis shows `DPL-0009` crossing 0.65 exactly when legalization blew up, which
makes it a usable proxy. The headroom check (D2) uses it as such and says so in its message.

### D2 — Headroom warning after `dpl`, in the driver

After the `dpl` stage, `run_pnr.sh` reads `DPL-0009` from `pnr_dpl.log` and the effective
density target (D1). It prints both on one line and emits `::warning::` when utilization is at
or above the target. The pnr.yml step summary already shows the driver's output and the status
log, so nothing else needs wiring.

- **Why in the driver.** It owns the stage logs and already turns them into CI annotations.
  Doing it in Tcl inside `dpl.tcl` would need a utilization query that OpenROAD's API does not
  expose more simply than the log line does.
- **Why not fail the run.** A design over the target may still legalize, as the 09-19 run did
  in 1h45. The stage timeouts stay the only failure mechanism, as `pnr-flow` requires.

### D3 — Measure on a resumed run first, then the full reference

1. **Resumed run (cheap density check).** Restore the `pre_place` checkpoint of a run on the
   current netlist, excluding `gpl` and later stages, with `stop_after cts`. That costs about
   `gpl` + `dpl` + `cts` time, roughly 6 h. If no such checkpoint survives, this step merges
   into step 2.
2. **Full run on `main` after merge.** A fresh run through `grt` (and best-effort `drt`) on the
   current pre-coprocessor tree. It becomes the reference: stage reached, WNS and power,
   recorded in Phase 11 and quoted by `sha3-cvxif-coprocessor` task 5.4.

Both are compared against run `34938462965` (pre-upgrade, reached `grt`) on: `DPL-0009`
utilization, illegal cells at legalizer iteration 0, `dpl`/`cts` runtimes, HPWL after
`dpl`/`cts`, `grt` congestion (total demand and Metal3, against 101.17 % and 115.27 %), and WNS.
Every dispatch needs the user's go-ahead (expensive targets, AGENTS.md).

### D4 — Fallback: timeouts only

If `grt` congestion gets materially worse at 0.72, keep 0.65 and raise only the `dpl`/`cts`
timeouts (7200 → 14400 s, 14400 → 28800 s). The run summary must name it as a fallback that
accepts the 29 % HPWL loss. "Materially worse" means total demand or Metal3 above the 09-15 run
by more than 5 points, or `grt` itself failing. This is a decision point for the user, not
something the implementation switches to by itself.

## Risks / Trade-offs

- **[Denser placement worsens `grt` congestion]** → D3 measures it against the 09-15 figures,
  and D4 gives a defined fallback. The success gate is `grt`, and `drt` stays best-effort.
- **[`DPL-0009` is a proxy, not the `gpl` target's own metric]** → The warning names both values
  and says what each is. 2.5 points of margin absorb the mismatch, which the diagnosis shows
  lining up in practice.
- **[Runner speed varies run to run (09-19 vs 09-26 on one netlist)]** → Success means finishing
  with margin, not just finishing: `dpl` well under its 2 h, near the 09-15 run's 1h28.
- **[Old and new P&R figures become incomparable]** → The reference run (D3 step 2) re-baselines
  `main`; the infra plan and the SHA-3 change's task 5.4 quote only figures on the new settings.
- **[0.72 is outgrown later, e.g. by the MMIO arm or a tool bump]** → The D2 warning names it on
  the first run that crosses, and the D1 override allows a test without a commit.

## Migration Plan

Merge to `main` after the resumed run (D3 step 1) shows `dpl` and `cts` within their timeouts.
Then dispatch the full reference run (D3 step 2). Rollback is reverting the one value (or setting
`PNR_GPL_DENSITY=0.65`), which restores today's behaviour exactly.
