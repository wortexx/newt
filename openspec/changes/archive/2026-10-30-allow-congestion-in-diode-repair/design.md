# Design

## Context

See proposal.md (Why) for the motivation. Current state after `finish-antenna-diode-repair` (OpenROAD `2c56926971`, read from its source):

- **`ant.tcl`, full mode:**
  1. `repair_antennas -jumper_only`, then save `ant_jumper`.
  2. One `pnr_detailed_placement -incremental`, which sets the sticky diamond flag.
  3. `repair_antennas -diode_only`, then save `ant`.

  The stage is a fresh `openroad` process, so no `global_route` call has run in it.
- **The engine is FastRoute.** The flow never passes `-use_cugr`, and `GlobalRouter::ensureEngineSelected` only switches to CUGR when the block carries that property. `repair_antennas` on guides calls `initFastRoute` and repopulates edge usage from every net's saved guides, so the global route's overflow is back in FastRoute's grid.
- **`allow_congestion_` is per call.** Both `global_route` and `repair_antennas` set it from their own `-allow_congestion` flag; the default is false. `grt.tcl` and `grt_repair.tcl` pass the flag; `ant.tcl` does not.
- **The diode step's reroute** is `IncrementalGRoute::updateRoutes` → `updateDirtyRoutesFastRoute`:
  - `updateDirtyNets` keeps only dirty nets whose guides cannot be reloaded, or whose pins changed position. If none is left, it returns early.
  - Otherwise it reroutes them. Then, `if (totalOverflow() && !allow_congestion_)`, it runs up to 31 rounds. Each round collects every net crossing an overflowed gcell, rips those nets up and reroutes them all. The last round runs a full `detailedPlacement(0, 0, "")`.
  - If overflow remains after that, it logs the congestion report and raises `GRT-0232`, which ends the stage with an error.
  - FastRoute runs with `setVerbose(false)` here, and `GRT-0009 rerouting N nets` is logged only when the router's `verbose_` is set. That fits the silent 3 h 52 m on run `40399844770`.
- **`repair_antennas` accepts `-allow_congestion`**: `GlobalRouter.tcl` sets `grt::set_allow_congestion` from it before calling `repairAntennas`.

## Goals / Non-Goals

**Goals:**

- The diode step's reroute treats existing overflow the way the flow's own global route does.
- A run shows whether the reroute now ends, how many nets it rerouted, and how long the whole diode step took.

**Non-Goals:**

- Post-route repair. If this change's run still times out, that becomes the next candidate, and it needs the same flag (D4).
- Reducing the global route's overflow, which belongs to the layout changes.
- Changing the default from jumper-only. That is a follow-up change, if D4's first row holds.

## Decisions

### D1. Pass `-allow_congestion` to the diode call only

`repair_antennas -diode_only -allow_congestion`. The jumper call is unchanged: with FastRoute, `jumperInsertion` saves guides and re-checks, and the reroute in that branch runs only for CUGR. So the flag would have no effect there, and leaving it off keeps the jumper result byte-identical to run A's.

- *Why not reduce overflow first:* every layout lever moves the thesis figures, and run A's overflow (7,153) is accepted by `grt` and `drt` already.
- *Why not `-iterations`/`-ratio_margin`:* neither reaches the overflow loop.
- *What the flag gives up:* the reroute may leave a diode net's guides through congested gcells. `grt` does the same for every net, and `drt` resolves it or reports it in its violation count.

### D2. Make the reroute observable

Before the diode call, `ant.tcl`:

- calls `grt::set_verbose 1`, so the reroute logs `GRT-0009 rerouting <n> nets`;
- records `[clock seconds]`.

After the call it logs `Diode step: <s> s (congestion allowed)`. Before the call it logs `Diode reroute: congestion allowed`.

`report_ant_outcome` adds `rerouted=<n>` (the last GRT-0009 after the `Antenna repair: diodes` marker, empty if none) and `diode_s=<s>` (empty when the stage was killed) to the `ant-repair` row. If the log shows a `GRT-0232` after the marker, it also prints a `::warning::`, because with the flag that should not happen.

- *Why `grt::set_verbose`:* it is the setter `global_route -verbose` uses. It is an internal Tcl namespace, like the sticky legalizer flag D2 of `finish-antenna-diode-repair` relies on. If a later OpenROAD drops it, the stage fails loudly at that call, before the diode step.
- *Alternative:* time from the GRT-0015 timestamp. That only has minute resolution, and it leaves out the net count.

### D3. Local probe before the VM run

On run A's `grt_repaired` (the same input as the `finish-antenna-diode-repair` probe), in one process under emulation: jumpers, the incremental diamond call, then `repair_antennas -diode_only -allow_congestion` with `grt::set_verbose 1`, with an 8 h wall-clock limit. Record:

- whether it returns;
- the GRT-0009 net count;
- the time from GRT-0015 to return;
- any GRT-0232.

The earlier probe ran without the flag and did not return in about 3 h. If this one returns, that confirms the overflow loop was the hang. If it does not, the GRT-0009 count still shows whether the rerouted set is small, and the VM run (about 16× faster than emulation here) decides.

**Probe result (2026-10-28, `newt-eda:dev`, OpenROAD `2c56926971`, log in `target/ihp13/openroad/out/local-ant/reports-ac/`):**

- `grt::set_verbose` exists in the image.
- Jumpers matched run A: 15,557 on 9,647 nets. The incremental diamond call ran (DPL-1101).
- The diode step inserted 18,902 diodes, legalized with diamond, and logged **`GRT-0009 rerouting 21011 nets`**: the diode nets plus about 2,100 others, not the whole design.
- **It did not return.** The 8 h limit killed it (exit 124) with nothing logged after GRT-0009, and **no GRT-0232**.
- GRT-0009 was logged once. The overflow loop's rounds reroute through the same path, and none of them logged it, so the probe never left the first reroute.
- The host slept for part of the night, so the log's timestamps include the gaps. Process time shows at least 4 h 43 m of run time after GRT-0009 under emulation, which is roughly 18 min or more on the VM.
- So the probe confirms the flag reaches the reroute (no GRT-0232), and the rerouted set is modest. It cannot tell a slow emulated FastRoute pass from a hang. As planned, the VM run (D4) decides: its rows "`ant ok`" and "times out with GRT-0009 logged" tell the two apart.

### D4. The measured run and how to read it

Dispatch from run A (`40081935481`): `resume_exclude=drt final`, `antenna_repair=1`, all else default. This is the same dispatch as run `40399844770`, so the only difference is this change.

| outcome | next step |
| --- | --- |
| `ant ok antenna=full`, antenna nets ≤ 1,173 (10 % of 11,732), router count within 2× of A's 8 | Record it, and propose full repair as the default in a follow-up, with the requote refreshed if WNS moved. |
| `ant ok`, antenna nets still well above 1,173 | Record the leftover by layer and ratio band. Next: `-ratio_margin`, or a second diode pass. |
| `ant ok`, router count much worse than A's | Diodes crowd pin access. Record it, and try fewer diodes before any default change. |
| `ant` times out again, with GRT-0009 logged | The reroute itself is too slow even without the overflow loop. Next: post-route repair with `-allow_congestion`. |
| `ant` fails with `GRT-0232` | The flag did not reach the reroute. Stop and read the source again before anything else. |

### D5. The SDC's Hyperbus pad lookup must tolerate diodes

Run `40749507442` (D4's dispatch) gave `ant ok antenna=full` with `rerouted=21011 diode_s=13139`. Then `drt` failed on its first command, `read_sdc`, with `STA-2204 get_property <obj> <obj> is not an object` at `basilisk.sdc` line 450, the end of the Hyperbus block.

- The block finds the pad behind each DDR output mux as `get_name [get_fanout -from $mux_out -only_cells -endpoints_only]`, which assumes the mux output drives exactly one cell.
- Full repair puts an antenna diode (`sg13g2_antennanp`, one input pin `A`) on that long mux-to-pad net. The lookup then returns two cells, and `get_name` fails on the list.
- `ant.tcl` reads no constraints, so the first stage to hit this is `drt`. Jumper-only runs never add cells there.

The fix is in `basilisk.sdc`. A `hyp_pad_of` proc picks the `*i_pad` cell out of the fanout by name, as the USB constraints already do. It errors unless it finds exactly one, so a pattern that stops matching fails loudly instead of yielding `/DIN`.

- Without diodes the pad is the only endpoint, so the constraints are unchanged. The thesis figures and scheduled runs are unaffected.
- The serial-link lookup (`SLO_CLK_CELLS`) needs no change. It keeps only pins named `S`, and a diode has none.
- *Why not exclude `sg13g2_antennanp` instead:* matching the pad by name also holds if repair ever puts another cell type on that net.

Checked locally by loading both checkpoints (`pnr_load` reads the SDC):

- `ant` from this run must load, and for every mux it must list the fanout and the pad found;
- `grt_repaired` must give the same pad as the old lookup for every mux.

**Result (2026-10-29, `newt-eda:dev`; logs in `target/ihp13/openroad/out/ci-40749507442/sdc-check/`):**

- On run `40749507442`'s `ant`, the SDC now loads. Four of the nine mux-to-pad nets carry a diode: `hyper_dq_o_0_`, `_5_` and `_6_` (`ANTENNA_18540`–`18542`), and `hyper_rwds_o_0_` (`ANTENNA_18543`). The old lookup fails on all four, and `hyp_pad_of` finds the right `pad_hyper_*.i_pad` for all nine.
- On `grt_repaired` (no diodes), the old and new lookups give the same pad for all nine muxes.
- None of the nine nets is dont-touch. `pnr_set_pad_dont_touch` covers the pad-to-port side, so `repair_antennas` may legitimately add a diode here.

The re-dispatch resumes from this run (`resume_exclude=drt final`), so it reuses this `ant` result instead of spending another 3 h 45 m. The `ant` stage used 3 h 45 m of its 4 h bound, so full repair cannot become the default without a longer `PNR_TIMEOUT_ANT`.

## Risks / Trade-offs

- **[The hypothesis is wrong, and the hang is elsewhere in the reroute]** → D3's probe and D2's log lines tell the two apart. The 4 h bound and the `ant_jumper` fallback still hold, so a wrong guess costs one run.
- **[More rerouted nets than expected, since every pin that moved is dirty]** → the GRT-0009 count measures it. Diamond keeps legal cells in place (the earlier probe moved none in the incremental call), so the set should be the diode nets and their neighbours.
- **[`grt::set_verbose 1` prints more than GRT-0009]** → FastRoute's own verbosity is forced off in the incremental path. Extra GRT lines only lengthen `pnr_ant.log`.
- **[Congested diode guides cost detailed routing]** → the router count in D4 measures it, against A's 8.

## Migration Plan

1. Land D1–D2. Scheduled runs are unchanged, since jumper-only never reaches the diode step.
2. Run the probe (D3) and record it in this design.
3. Ask, then dispatch D4. Record the result in `docs/infra-plan.md`.
4. Rollback: revert. `ant.tcl` returns to the bounded, hanging diode step.
