# Design

## Context

See proposal.md (Why) and docs/infra-plan.md, "What is left of DRC, 2026-10-21", for the measurements. The current flow has these pieces:

- `pnr_apply_routing_layers` (`common.tcl`) sets the per-layer global-routing adjustments: Metal2 from `PNR_GRT_METAL2_ADJUST`, Metal3 0.30, TopMetal1 0.20, and nothing on Metal5. Every stage from `grt` on calls it after loading its checkpoint, because each stage is its own OpenROAD process.
- `drt.tcl` runs a bare `repair_antennas` unless `PNR_SKIP_ANTENNA_REPAIR=1`. The lane passes 1 unless `antenna_repair=1`. Neither `drt.tcl` nor `final.tcl` runs `check_antennas`.
- `run_pnr.sh`'s `report_drt_outcome` takes the router's counts from `pnr_drt.log` (DRT-0199) and writes a `drt-violations` status row, which `pnr.yml`'s summary prints together with `basilisk.drt.violations.txt`.
- The local OpenROAD (`newt-eda:dev`, 26Q3-1740-g2c56926971) has `repair_antennas [-jumper_only] [-diode_only] [-ratio_margin]`. `check_antennas` logs `ANT-0002 Found N net violations` and `ANT-0001 Found M pin violations`. On run `39244019401`'s `drt` checkpoint it found 11,732 / 15,605 and wrote a 103 MB report.

## Goals / Non-Goals

**Goals:**

- Global routing sees roughly the Metal5 capacity the SRAM pad field actually leaves.
- Every routed run states its antenna count.
- One run answers two questions, each against run `39244019401`: does the hold-back clear the SRAM shorts, and does antenna repair now finish on this layout?

**Non-Goals:**

- Tuning the hold-back across several values in this change. One value is measured; a second only if the first misses (D5).
- Changing `repair_antennas` beyond choosing its mode, for example `-ratio_margin` or iteration count.

## Decisions

### D1. Hold Metal5 back per SRAM region, not per layer and not by blockage

`pnr_apply_routing_layers` calls `set_global_routing_region_adjustment` on Metal5 once for every SRAM instance (`ref_name` `RM_IHP*`), with that instance's bounding box. It does so only when `PNR_GRT_SRAM_METAL5_ADJUST` (new, default 0) is above 0. It logs the value and the number of regions.

- *Why a region:* over the SRAMs only 43 % of Metal5 tracks clear every pad row, while elsewhere Metal5 carries normal traffic. A layer-wide adjustment would take capacity from the whole die to fix 32 footprints.
- *Not a routing blockage:* a Metal5 blockage over the macros would also bind detailed routing and forbid every crossing. The 66–126 nets per macro that do cross cleanly today would have to detour.
- *Not a PDN change:* fewer or x-aligned via stacks would raise the free share itself. But it changes the macros' supply, needs an IR-drop argument, and its `pdngen` support is unchecked. It stays the next lever (proposal Non-goals).
- *All 32 SRAMs, not only the three hot ones:* the R0/R180 macros share the pad structure. The rotated ones join TopMetal2 to Metal3/Metal4, so their stacks pass through Metal5 too. Choosing the three hot macros would fit this one layout.

**Value for the run: 0.55.** That leaves `grt` about 45 % of Metal5 over the macros, against the 43 % (706 of 1,635 tracks) measured to clear all pad rows. It is a little above 43 % because some nets only enter the macro from a channel and never cross all eight rows.

Before writing code, read `set_global_routing_region_adjustment`'s proc body and its C++ in this build. Check that it takes microns, that it applies only to the given layer, and that calling it once per region works. `drt.tcl`'s history shows that reading `define_cmd_args` is not enough.

*Checked 2026-10-21 (task 1.1), proc body in `newt-eda:dev` and `src/grt/src/GlobalRouter.cpp` at `2c56926971`:*

- *Units: microns.* The proc multiplies each corner by the tech's DBU per micron before calling `grt::add_region_adjustment`. Each corner must pass `check_positive_float`, and the region must lie inside the die (GRT-0072).
- *One layer:* `-layer` is resolved to a single routing-layer index. `computeRegionAdjustments` changes only that layer's edges in the gcells the region covers. Boundary gcells get a partial reduction.
- *Repeated calls add regions:* `addRegionAdjustment` appends to `region_adjustments_`. Every `initFastRoute` (each `global_route`, and `-start_incremental`) clears FastRoute, resets capacities, and then applies the whole list once. Incremental reroutes therefore do not compound.
- *What does compound:* each entry scales the edge capacity left by the entries before it. A second call of `pnr_apply_routing_layers` in one process would hold back 0.55 twice, leaving about 20 %, and so does a gcell that two adjacent SRAM boxes share. Every stage calls the proc once today. It still adds the regions only on its first call in a process, so the setting stays idempotent like the per-layer ones. Shared boundary gcells are accepted: they are a column at the edge of a macro pair, inside the hold-back's intent.
- The list lives only in the GRT object, not in the `.odb`. Each stage re-applies it after loading its checkpoint, as it does for the layer adjustments.

### D2. Antenna repair mode as a second value of the existing input

`antenna_repair` accepts: empty (skip, as today), `1` (full repair, today's meaning, kept for existing dispatch habits) and `jumper` (`repair_antennas -jumper_only`).

- `pnr.yml` passes the mode to the flow as `PNR_ANTENNA_REPAIR_MODE` (`full` | `jumper`), next to the existing `PNR_SKIP_ANTENNA_REPAIR`.
- `pnr.yml` rejects any other value in a step before P&R starts. `drt.tcl` also rejects an unknown mode, so a local run cannot misspell it either.
- The `drt` status line records `antenna=skipped|full|jumper`.
- *Checked 2026-10-22 (task 2.1):* on run `39244019401`'s `grt` checkpoint, with Metal2 0.60 and the SRAM Metal5 hold-back at 0.55, `repair_antennas -jumper_only` returned cleanly after 33 min under local emulation. It inserted 15,088 jumpers on 9,462 nets, and global routing's antenna estimate fell from 12,339 to 4,885 violations (GRT-0012). That figure is global routing's estimate, not `check_antennas` on routed wires, but it shows that the D5 jumper fallback has room.
- *Alternative:* a separate `antenna_mode` input. Rejected: two inputs that only make sense together invite contradictory dispatches.

### D3. Antenna check inside `drt`, counts from the log

After `detailed_route`, and before `save_checkpoint`, `drt.tcl` runs `check_antennas -report_file reports/basilisk_antenna.rpt`. The check sits inside its own `catch`, so a failing check is logged and the stage still ends `ok`.

`run_pnr.sh` gains `report_antenna_outcome`, modelled on `report_drt_outcome`. It reads the last `ANT-0002` and `ANT-0001` lines from `pnr_drt.log` and writes the status row `drt-antenna nets=<N> pins=<M>`, or `drt-antenna none` when no line was logged. `pnr.yml`'s summary prints that row with the others and adds one line naming the report file.

- *Why `drt` and not `final`:* the count then belongs to the stage that made the wires, and it is also reported when `final` fails.
- *Why the log, not the report file:* the same reasoning as the router's counts (drc-clean-pnr D2). The file is a detailed listing of 100+ MB, and counting its entries is fragile.
- *Report size:* the reports artifact is compressed when uploaded, so the 103 MB text costs far less there. If it is still too large, keep only the counts and the first 1,000 nets. That is an implementation choice and does not touch the spec.

### D4. The measured run

Dispatch `pnr.yml` on the change's branch with:

| input | value |
|---|---|
| `resume_from_run` | `39244019401` |
| `resume_exclude` | `grt grt_repaired drt final` |
| `die_scale` / `gpl_density` / `grt_metal2_adjust` | `1.25` / `0.50` / `0.60` (that run's settings) |
| `sram_metal5_adjust` | `0.55` |
| `antenna_repair` | `1` |
| `drt_end_iter` | `28` |

`drt_end_iter=28`: the baseline's iterations took 16 h 49 m for 33 (0–32), so 29 iterations take about 14.5 h. That leaves about 9 h of the 24 h `drt` timeout for `repair_antennas` and the check. Ending inside the timeout keeps the checkpoint and the DEF (the lesson from run `39111124087`). The baseline's count after iteration 28 is **138**, so the comparison is at equal iterations.

Compare, against run `39244019401`:

- the router's count after iteration 28 (138), and whether any violation is left inside an SRAM footprint;
- the antenna counts (11,732 nets / 15,605 pins, from the local check on its `drt` checkpoint);
- `grt` overflow (2,529) and WNS at `grt` (−11.02 ns);
- `repair_antennas` run time, and the jumpers and diodes it inserted.

### D5. Reading the result

| outcome | next step |
|---|---|
| router count < 138 and no violation over an SRAM, antenna nets ≤ 10 % of 11,732 | Record in docs/infra-plan.md. Propose adopting both as lane defaults in a follow-up change, together with the thesis requote. |
| SRAM shorts remain, fewer than before | One more value, 0.70, from this run's own `grt` checkpoint excluded, same other inputs. |
| router count rises (channels overloaded) | Re-dispatch from the same `cts` with the hold-back and no antenna repair, to separate the two effects before choosing. |
| `repair_antennas` stalls, or `drt` times out | Re-dispatch from this run's `grt` with `antenna_repair=jumper`. |
| antenna nets well above 10 % after full repair | Record the leftover by layer from `basilisk_antenna.rpt`. A follow-up chooses between `-ratio_margin`, more repair iterations, and holding Metal2 back less (Metal4 carries 74 % of the violations). |

## Risks / Trade-offs

- [The hold-back pushes nets into the 30 µm channels, which overload on Metal2/Metal3] → `grt` overflow and the router's per-layer table are compared directly. D5's third row isolates the cause.
- [The detours worsen timing, already at WNS −11.02 ns] → Recorded, not gated. Timing is not this change's goal, and the requote change decides which settings the thesis uses.
- [Antenna repair and the hold-back both change routing, so one run confounds them] → Accepted, to save a 20 h run. D5 says which follow-up separates them if the result is ambiguous.
- [`repair_antennas` hangs again, as on the 101 %-demand layout] → This layout is at 46 % utilization with 2,529 overflow edges. `drt_end_iter=28` leaves headroom. A timeout loses only this run, and D5 names the jumper-only retry.
- [The region adjustment silently has no effect, or applies to the wrong units] → D1's pre-check of the proc body, and the stage log's region count and value. The run also confirms it: `grt` reports Metal5 usage per layer.
- [The always-on check lengthens scheduled runs] → Minutes on the VM. The local emulated run, load included, took about 12 min.
