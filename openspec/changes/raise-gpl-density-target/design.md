## Context

The P&R lane (`.github/workflows/pnr.yml`) runs the staged driver `target/ihp13/openroad/run_pnr.sh`.
Each stage is an OpenROAD script under `scripts/pnr/`, with its own wall-clock timeout
(`STAGE_TIMEOUT_DEFAULT`) and its own checkpoint. `gpl.tcl` runs two global-placement passes:

- **Pass 1** is routability-driven. It only provides parasitics.
- **Between the passes**, a real `repair_design` and `repair_timing -repair_tns 70` run on
  pass 1's placement.
- **Pass 2** is routability- and timing-driven, and carries forward to `dpl`.

The monolithic `scripts/chip.tcl`, which the staged scripts were adapted from (`ci-pnr-lane`
D1), carries the same settings.

The diagnosis is in `docs/infra-plan.md` Phase 11, corrected on 2026-10-03 from the `pnr-reports`
of runs `34938462965` (09-15, good), `36188933699` (09-26, 0.65) and `37037836332` (0.72). In
all three, pass 2 behaves the same way:

- Its second timing-driven iteration (`GPL-0100 … virtual: false`) runs a real `repair_design`
  at overflow ≈ 0.2. That adds 0.9–1.2 mm² of buffers (`GPL-0107`, +5–7 %).
- The target density then jumps (`GPL-0110`: 0.895 / 0.993 / 1.043).
- Nesterov diverges and reverts (`GPL-0999`, overflow 0.189 / 0.218 / 0.217).
- `dpl` starts from 82,811 / 203,229 / 223,074 illegal cells.

Run `37037836332` shows that raising `-density` makes it worse: it raises the base that the jump
starts from.

The lane already supports partial runs: `resume_from_run`, `resume_exclude` and `stop_after`.
OpenROAD's `global_placement` has `-keep_resize_below_overflow`: a timing-driven iteration keeps
its `repair_design` changes only below this overflow. Its default, 1.0, keeps them all; the log
prints "keep resizer changes at: 1".

## Goals / Non-Goals

**Goals:**

- `gpl` pass 2 converges, without a divergence revert, and `dpl`/`cts` legalize from a
  near-legal placement on the current netlist and on the SHA-3 coprocessor's netlist.
- A clean pre-coprocessor P&R reference on `main` (the stage reached, WNS and power), on the
  settings the coprocessor run will use.
- A run whose placement did not converge says so in its output.

**Non-Goals:**

- Detailed-route convergence (Phase 11's `drt` blocker) stays best-effort, as `pnr-flow`
  already specifies.
- Timing closure.
- Tuning routability settings, the repair between the passes, or the floorplan.

## Decisions

### D1 — Virtual timing-driven repair in pass 2; density back to 0.65

Pass 2 gets `-keep_resize_below_overflow $pnr_gpl_keep_resize`, defined in
`scripts/pnr/common.tcl` with default `0`. That makes every timing-driven iteration virtual: it
runs `repair_design` to weight timing-critical nets, then undoes the changes. `pnr_gpl_density`
returns to `0.65`. Both values are overridable without a commit: `PNR_GPL_KEEP_RESIZE` and
`PNR_GPL_DENSITY`, and the `pnr.yml` inputs `gpl_keep_resize` and `gpl_density`.
`scripts/chip.tcl` carries the same values.

- **Why this lever.** The buffers that pass 2's iteration inserts are what move the density
  target and set off the divergence, in the good run too, only less. Making the iteration
  virtual removes the trigger without losing timing awareness: net re-weighting still happens.
  The design-rule and setup repair that matters already runs between the passes, on a
  converged pass-1 placement, and `cts`'s `repair_timing` runs again later.
- **Why 0 and not a lower threshold.** The iterations run at overflow ≈ 0.64 and ≈ 0.2. Any
  threshold below 0.2 behaves like 0 here, and 0 says what is meant.
- **Why not cap routability** (`-routability_max_density`). `gpl` already reverts the
  routability inflation itself (`GPL-0055`), back to the least-congested iteration, so a cap
  would not touch the jump that matters.
- **Why density 0.65.** Upstream's value, and the one that worked on the 09-15 netlist. 0.72 was
  measured to be worse. Keeping it overridable allows a later test without a commit.
- **Cost.** Fewer buffers after `gpl` may mean worse setup timing entering `cts`. It is measured
  (WNS at the latest stage), not gated.

### D2 — Placement report after `dpl`, in the driver

After the `dpl` stage, whether it passed or not, `run_pnr.sh` prints one line:

- whether `gpl` pass 2 reverted after a divergence (`GPL-0999` after the "Global Placement (2)"
  marker) and the overflow it reverted to;
- the final placement area (`GPL-1014`);
- `dpl`'s utilization (`DPL-0009`);
- the illegal cells at the negotiation legalizer's iteration 0.

A pass-2 revert emits `::warning::`. `dpl` logs the last two values before it legalizes, so the
line is complete even when `dpl` times out. With no `gpl` log (a resumed run that restored the
placement), the line says it was not reported. It replaces the headroom check, whose
utilization-versus-density premise D1's evidence disproved.

- **Why in the driver.** It owns the stage logs and already turns them into CI annotations.
- **Why not fail the run.** An unconverged placement may still legalize in time, as the 09-15
  run did. The stage timeouts stay the only failure mechanism, as `pnr-flow` requires.

### D3 — Timeouts as a safety net

`dpl` goes from 7,200 to 14,400 s, and `cts` from 14,400 to 28,800 s. A timeout only bounds wall
time. The logs record the actual runtime, so a run still shows whether D1 alone fits the old
limits. Without the safety net, a near-miss would cost another ≥ 10 h run. The `pnr.yml` job
ceiling (48 h) covers the worst case: `gpl` 4 h + `dpl` 4 h + `cts` 8 h + `grt` 16 h.

### D4 — One measured run, then the reference

No checkpoint matches the current netlist (task 3.1), so the measurement is one full run on this
change's branch, with `stop_after=grt`. It stops after `grt`, not `cts`, because a
better-converged placement can move congestion into routing. It is compared against run
`34938462965` on:

- `gpl` pass-2 convergence;
- illegal cells at iteration 0;
- `dpl` and `cts` runtimes;
- HPWL after `dpl` and `cts`;
- `grt` congestion (total demand and Metal3, against 101.17 % and 115.27 %);
- WNS.

If it reaches `grt`, merge, and the run on `main` that follows is the pre-coprocessor
reference. The netlist is the same, so it is a re-run on `main`, needed only because the
reference must come from `main`'s settings. Every dispatch needs the user's go-ahead.

## Risks / Trade-offs

- **[Virtual repair leaves timing worse after `gpl`]** → `cts`'s `repair_timing` still runs.
  WNS is recorded at the latest stage; it is not a gate.
- **[Pass 2 still diverges for another reason]** → The D2 report names it on that run.
  `gpl_keep_resize=1.0` reproduces the old flow for an A/B without a commit.
- **[Better placement moves congestion into `grt`]** → D4 stops after `grt` and compares
  against the 09-15 figures. `grt` is the gate; `drt` stays best-effort.
- **[Old and new P&R figures become incomparable]** → The reference run re-baselines `main`.
  The infra plan and the SHA-3 change's task 5.4 quote only figures on the new settings.

## Migration Plan

Merge to `main` after the D4 run reaches `grt`. Rollback is setting `PNR_GPL_KEEP_RESIZE=1.0`
(and, if wanted, the old timeouts), which restores the previous placement behaviour exactly.
