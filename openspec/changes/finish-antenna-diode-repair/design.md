# Design

## Context

See proposal.md (Why) for the motivation. Relevant current state, after `adopt-drc-clean-defaults-and-requote`:

- **Stages:** `run_pnr.sh` runs `floorplan pre_place gpl dpl cts grt grt_repair drt final`, each in its own `openroad -exit` process with its own timeout.
  - A stage counts as done when its checkpoint zip exists, which is also how a resume skips it.
  - A failed best-effort stage after the gate makes every later stage `skipped predecessor-failed`.
  - `load_checkpoint` reads `<name>/<name>.{v,odb}` from inside `<name>.zip`, so a checkpoint cannot be renamed by renaming its zip.
- **`drt.tcl`** loads `grt_repaired`, then runs `repair_antennas` (`-jumper_only` by default, full on request, or none), then `detailed_route`, then `check_antennas`.
- **`repair_antennas`** (`GlobalRouter::repairAntennas`, OpenROAD `2c56926971`) runs these steps:
  1. Check on the global routes.
  2. Jumper insertion, saving guides, and a re-check (GRT-0302, GRT-0012).
  3. Without `-jumper_only`: `RepairAntennas::repairAntennas`, which inserts the diodes and calls `opendp_->detailedPlacement(0, 0, "")`. That is non-incremental, so every movable cell is unplaced and legalized again.
  4. GRT-0015 "Inserted N diodes".
  5. `IncrementalGRoute::updateRoutes()` on every dirty net.

  Run `39696194006` logged step 4 and then nothing for about 23 h, so the hang is step 5 or later. The legalization in step 3 was negotiation (DPL-1102) and stopped after 1,400 iterations with 9,663 violations (DPL-0701).
- **The legalizer choice is sticky.** `Opendp::detailedPlacement` does `use_diamond_legalizer_ |= use_diamond_legalizer`. Once any call in the process asks for diamond, later calls, including `repair_antennas`' internal one, use diamond. `drt.tcl` makes no placement call before repairing, so the internal call gets negotiation.
- **The flow's legalizer** is `pnr_detailed_placement` in `common.tcl`: diamond, window 1000 × 1000 µm, used by `dpl`, `cts` and `grt_repair`.

## Goals / Non-Goals

**Goals:**

- A diode-repair stall or hang costs only the antenna stage's timeout. Detailed routing still runs, on the jumper result.
- Diode insertion re-legalizes with the flow's legalizer and moves as few cells as possible.
- One measured run says whether full repair can become the default.

**Non-Goals:**

- Post-route antenna repair, with diodes after `detailed_route` and a routing ECO. It is named as a fallback (D5), not built.
- Tuning `-ratio_margin` or `-iterations`.
- Changing `check_antennas` or the `drt-antenna` reporting. It still runs after `detailed_route`, on whatever was routed.

## Decisions

### D1. A new stage `ant` between `grt_repair` and `drt`, with two checkpoints

`run_pnr.sh`'s stage list becomes `… grt grt_repair ant drt final`. Its completion checkpoint is `ant`. `ant.tcl`:

1. Loads `grt_repaired` and applies the routing setup that `drt.tcl` applies today: pad dont-touch, dont-use and routing layers. Guide bridging (`pnr_bridge_wrong_way_guides`) stays in `drt.tcl`, after loading the antenna result and before `detailed_route`, so it sees the guides that repair rewrote. Before this change it ran before repair, in the same process.
2. In mode `skip`: saves `ant` unchanged and reports `ant ok antenna=skipped`.
3. Runs `repair_antennas -jumper_only` and saves checkpoint `ant_jumper`.
4. In mode `jumper`: also saves `ant` from the same design, and reports `ant ok antenna=jumper`.
5. In mode `full`: selects diamond (D2), runs `repair_antennas -diode_only`, saves `ant`, and reports `ant ok antenna=full`.

`drt.tcl` loads `ant` if its zip exists, otherwise `ant_jumper`. It no longer calls `repair_antennas`, and its status detail records which checkpoint it routed (`input=ant|ant_jumper`).

*Local check (tasks 2.1, 2.2, 2026-10-26):* in the image, on run A's `grt_repaired`:

- An unknown mode exited 1 before loading.
- `skip` saved `ant` with `ant ok antenna=skipped`.
- No mode saved `ant_jumper` and `ant` with `ant ok antenna=jumper`, at the same 15,557 jumpers and 4,967 violations left as in 1.1.
- `drt.tcl` with `detailed_route` stubbed logged `input=ant` when `ant.zip` was present and `input=ant_jumper` when only `ant_jumper.zip` was.
- In both cases `check_antennas` ran (4,967 nets / 7,084 pins on the unrouted guides), and bridging reported 39 guides on 31 nets. Run `39906592139` reported the same before repair, so moving bridging after repair changes nothing for jumper-only.

`run_pnr.sh`: when `ant` fails or times out and `ant_jumper.zip` exists, it logs `ant failed exit=<rc> fallback=ant_jumper`. It does not set `best_effort_broken`, so `drt` runs. Without `ant_jumper.zip`, the usual predecessor-failed rule applies.

- *Why diodes run as a second call (`-diode_only` after `-jumper_only`) and not as one full call:* the jumper result has to be saved before the step that can hang. A single call would hold both in one uncheckpointed C++ call.
- *Why not a timeout inside `drt.tcl`:* Tcl cannot interrupt a running C++ command. Only a separate process can be bounded.
- *Why `ant` is saved even for `skip` and `jumper`:* one completion rule for every mode keeps resume and the stage table uniform. The cost is one load and save, a few minutes.
- *Timeout:* `PNR_TIMEOUT_ANT`. The `run_pnr.sh` default is 4 h, and `pnr.yml` sets 4 h. Jumper insertion took 4 min and diode legalization 32 min on run `39696194006`, so 4 h leaves room for a reroute several times longer than the legalization. The job ceiling still holds: about 6 h through `cts`, plus 2 h `grt`, 4 h `ant` and 7.5 h `drt`.
- *Resume:* a run made before this change has no `ant` checkpoint, so `ant` runs from its `grt_repaired`. `resume_exclude` gains the names `ant_jumper` and `ant`.

### D2. Diamond for the diode re-legalization, through the sticky flag

Before `repair_antennas -diode_only`, `ant.tcl` calls `pnr_detailed_placement -incremental` once on the jumper-repaired, already legal design. That sets the process's diamond flag, so the internal non-incremental `detailedPlacement(0, 0, "")` uses diamond from the cells' current positions. Diamond searches outward from each cell's position, so cells that were legal mostly stay where they are. Only cells displaced by diodes should move, and with them the set of nets rerouted in step 5.

- The stage logs `Diode legalization: diamond (sticky from pnr_detailed_placement)`. The DPL lines inside `repair_antennas` must then show no `DPL-1102 Legalizing using negotiation legalizer`. DPL-0005 ("Diamond search max displacement") is not evidence on its own: run `39696194006` logged it immediately before DPL-1102 in the same negotiation legalization.
- The incremental call itself must not move cells on a legal design. That is checked locally by comparing every instance's location before and after.
- *Local check (task 1.1, 2026-10-26):* run A's (`40081935481`) `grt_repaired` checkpoint, one process in `newt-eda:dev` under amd64 emulation on an arm64 host, so times are several times the VM's (jumpers: 65 min here against 4 min on the VM).
  - The incremental diamond call logged `DPL-1101 Legalizing using diamond search` and moved nothing: all 978,757 instance locations were byte-identical before and after.
  - `repair_antennas -jumper_only`: 15,557 jumpers on 9,647 nets, 12,495 → 4,967 violations, as on the VM.
  - `repair_antennas -diode_only`: its internal legalization logged `DPL-1101` (diamond) and no `DPL-1102`, placed all 967,302 cells by diamond move with 0 failures in 40 s, and inserted 18,902 diodes (GRT-0015). Run `39696194006`'s negotiation legalization of the same diode set took 32 min and left 9,663 violations (DPL-0701). The sticky flag works on `2c56926971`.
  - The reroute after GRT-0015 did not finish within the local limit: about 3 h of emulated time, then the 4.5 h process timeout (load included). Emulation leaves open whether it finishes inside `ant`'s 4 h on the VM. That is what task 4.1 measures, with D1's fallback as the bound.
  - The internal call uses OpenROAD's default window (±500 sites, ±100 rows), not the flow's 1000 × 1000 µm one, because `-max_displacement` is not sticky. It still placed every cell.
- *Alternative:* patch OpenROAD so `repair_antennas` takes a legalizer flag. Rejected for now: a fork of the tool image is a larger change, and the sticky flag reaches the same code path.
- *Risk:* the flag being sticky is upstream behaviour, not API. A later OpenROAD bump could change it, and the log check in this decision detects that.

### D3. Reporting

`run_pnr.sh` gains `report_ant_outcome`, run after `ant` the way `report_drt_outcome` runs after `drt`. It reads `pnr_ant.log` and writes one status row: `ant-repair jumpers=<n> diodes=<m> legalizer=<diamond|negotiation> left=<DPL-0701 count or 0>`, or `ant-repair none`. The step summary prints it with the other rows. The `drt-antenna` row is unchanged and still counts the routed result.

### D4. The measured run

After `adopt-drc-clean-defaults-and-requote`'s input-less both-arms run (call it run A), dispatch from A's `grt` checkpoint:

| input | value |
|---|---|
| `resume_from_run` | A |
| `resume_exclude` | `drt final` |
| `antenna_repair` | `1` |

All other inputs empty, which are the new defaults. `ant` runs because A has no `ant` checkpoint. Compare with A:

- antenna nets / pins (A's own, about 8,627 / 11,287);
- the router count after iteration 28;
- `ant` time, jumpers, diodes, the legalizer and violations left;
- WNS at `drt` entry.

### D5. Reading the result

| outcome | next step |
|---|---|
| `ant ok antenna=full`, antenna nets ≤ 10 % of 11,732 (≤ 1,173), router count within 2× of A's | Record it. Propose full repair as the lane default in a follow-up, with the requote refreshed if WNS moved. |
| `ant ok`, but antenna nets still well above 1,173 | Record the leftover by layer and ratio band. Next candidate: `-ratio_margin` for marginal nets, or post-route repair. |
| `ant` timed out after diode insertion; `drt` routed `ant_jumper` | The bound worked; the reroute is the problem. Next candidate: post-route repair (diodes after `detailed_route`, then an incremental `detailed_route`), which needs no global reroute. |
| legalization still negotiation (log check fails) | The sticky flag did not reach the call. Stop: the OpenROAD patch alternative in D2 is the next step. |
| router count much worse than A | Diodes crowded pin access. Record it, and try fewer diodes with a lower `-ratio_margin`, before any default change. |

## Risks / Trade-offs

- **[The reroute hangs even with diamond]** → D1's bound and fallback make it a 4 h cost with a routed design still produced. D5's third row names the next lever.
- **[The incremental diamond call moves cells, or fails on a padded design]** → checked locally (D2). Cell padding defaults to 0, and the call goes through `pnr_detailed_placement`, which applies the same padding as `dpl`/`cts`.
- **[Two checkpoints add disk and upload time]** → about 230 MB each zipped, like `grt`. The upload job already handles 12 checkpoints.
- **[Stage-list change breaks resume names in docs or dispatch habits]** → `docs/pnr-pipeline.md` and the `resume_exclude` description list the new names. Old runs resume unchanged (D1).

## Migration Plan

1. Land D1–D3. Scheduled runs keep jumper-only by default and gain the `ant` stage, a few minutes longer.
2. Run D4 (ask first) and record it.
3. A follow-up change adopts full repair as the default only if D5's first row holds.
4. Rollback: revert. `drt.tcl` regains its in-process repair.
