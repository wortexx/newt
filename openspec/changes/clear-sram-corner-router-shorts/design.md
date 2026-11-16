# Design

## Context

See proposal.md (Why) for the two mechanisms. Current state, from the code and the 2026-11-16 probe of run `41133143603` (reports and DEF in the session scratchpad; the figures below are copied here so this design stands alone):

- **Where the shorts are** (all `Short`, router count 8, identical in `39906592139`, `40081935481` and `41133143603`):

  | id | box (µm) | layer | what |
  |---|---|---|---|
  | A | 485.7, 820.2 | Metal2 | `_004931_` crosses the rail pad of the core VSS stripe at x 482.9–490.9 |
  | B ×2 | 7030.5, 661.5 / 7029.6, 669.1 | Metal2 / Metal4 | `net87525` / `net117238` cross the rail pads under the VSS repair stub at x 7026–7034 |
  | C ×2 | 2916, 620–622 | Metal5 | `net140706` (driver `wire140707` at 2039.5, 521.6, in the inter-row gap) crosses I-cache `data_3_low` to reach `A_DIN[1]` |
  | D ×3 | 6987–6991, 628–655 | Metal5 | `bank_wdata_64_` (driver `_360008_` at 6993.6, 533.0, in the gap) crosses D-cache bank 0 cut 1 to reach `A_DIN[0]`, and meets 3 other nets jogging between the macro's TM1 pad rows |

- **The power grid.** It is built in `power_grid_stripes.tcl`, sourced by `scripts/pnr/floorplan.tcl` after `save_checkpoint basilisk.floorplan` and before `basilisk.power_grid`.
  - The core grid has three parts:
    - Metal1 follow-pin rails;
    - TopMetal2 stripes (6 µm wide, 138 µm pitch, VSS then VDD 54 µm apart);
    - `add_pdn_connect TopMetal2 Metal1`, which drops a full via stack (an 8 µm pad on Metal2–TopMetal1) on every rail under every stripe.
  - Each SRAM grid has a Metal3/Metal4 ring 2 µm off the macro, `add_pdn_connect Metal3 Metal1` to the rails, and TopMetal1 stripes.
  - `pdngen` runs once, with `-failed_via_report` and `-dont_add_pins`.
  - `verify` is hard-coded to 0, so `check_power_grid` never runs.
- **The stubs are channel repair.** The DEF holds 8 TopMetal2 straps shorter than the core:
  - VSS at x 2106, 5298 and 7030, and VDD at 6150;
  - each spans y 388–519 or 539–670, the bottom and middle macro rows.

  Each sits in a 90 µm gap between macros where the core stripe pair puts only one net. At x 7030, the core VSS stripe at 7001–7007 is pressed against the macro ring, and all 32 of its stacks in the macro rows are obstructed (`basilisk_pdngen.rpt`). The DEF's 8 are the gap stubs. The grid in the checkpoint holds 10: a VDD/VSS pair at x 7066–7076, y 6134–6268, next to an LLC macro, completes it.
- **Repair cannot be turned off** (OpenROAD `2c56926971`, read 2026-11-16). `Grid::makeShapes` calls `RepairChannelStraps::repairGridChannels` unconditionally. `pdn::allow_repair_channels` only decides whether a channel left unrepaired warns (on) or raises `utl::error` (off), so with it off pdngen still repaired all 9 channels in 4 passes (`set_debug_level PDN Channel 1`), giving the same 10 straps. No `pdngen`, `define_pdn_grid` or `add_pdn_stripe` option skips repair.
- **Removing the straps afterwards is safe** (probe on run A's `power_grid` checkpoint, 2026-11-16). Deleting the 10 straps, every via whose centre lies inside one (1,080) and every wire that lies wholly inside one (324 Metal5/TopMetal1 pads) leaves both nets' `check_power_grid` reports byte-identical to the unmodified grid. Selecting wires by centre instead also deletes Metal1 rail pieces crossing the strap, so containment is required.
- **`check_power_grid` on today's grid** (same probe, each check in its own process unless noted):
  - Without `-dont_require_terminals` it raises PSM-0025 (no terminals) at this stage. With it, adding `-floorplanning` changes nothing.
  - A failure raises a Tcl error (PSM-0069) and writes `-error_file`. About 80–95 s per net under emulation.
  - Today's grid fails on both nets with 14 reports each: 12 Metal1 rails at x 388.16–428.0 µm, y 4093–4181 µm, and the two Hyperbus delay lines on them (`i_delay_tx_clk_90`, `i_delay_rx_rwds_90`). This hole is not caused by the stubs.
  - Negative control: a floating 2 µm Metal5 square adds exactly one report. Two checks in one process are independent: a before/after pair with the square added between them reports it only after.
- **The Metal5 hold-back today.** `pnr_apply_sram_metal5_adjustment` (`common.tcl`) adds one region adjustment per `RM_IHP*` instance (32 in this design, 0.55 by default), on the first call in a process only. Region adjustments accumulate, and each one scales the capacity left by the earlier ones (checked in `drc-clean-sram-metal5-and-antenna` task 1.1).
- **SRAM pin side.** `RM_IHPSG13_1P_256x64` has all 695 signal pins on its `y = 0` edge, with `A_DIN[0]` 3.29 µm from x = 0. R180 puts them on the top edge, with bit 0 at the east end.

## Goals / Non-Goals

**Goals:**

- Remove the channel-repair stubs without leaving any rail unpowered, and prove that in the run itself.
- Make global routing route fewer nets over the SRAMs' ends, so more of them go around.
- Keep every default byte-identical to today, so the quoted figures and scheduled runs do not move until a follow-up adopts the settings.

**Non-Goals:**

- Moving or re-pairing the core TopMetal2 stripes. The D-cache macros repeat every 874.5 µm, and 874.5 mod 138 = 46.5, so no fixed-pitch pair can land both nets in every gap.
- Static IR-drop analysis. The connectivity check is the gate. IR drop is noted as a risk.

## Decisions

### D1. Channel-repair strap removal: `PNR_PDN_REPAIR_CHANNELS`

- **Parsing.** `common.tcl` parses `pnr_pdn_repair_channels` from `PNR_PDN_REPAIR_CHANNELS`:
  - empty means 1;
  - only `0` and `1` are accepted;
  - anything else errors with the variable's name.
- **What 0 does.** pdngen runs exactly as today. Afterwards, `power_grid_stripes.tcl` removes, per net:
  - every TopMetal2 strap shorter than the core height minus 1 µm (the repair straps; the core stripes span the core);
  - every via whose centre lies inside such a strap;
  - every other wire of the same net that lies wholly inside it.

  It logs `PDN channel repair: on|off` and, when off, `PDN channel-repair straps removed: <n> (<m> shapes under them)`.
- **Default.** `chip.tcl` (the legacy single-process flow) does not source `common.tcl`, so the script falls back to on when the variable does not exist. With 1, the script issues the same `pdngen` call as today and removes nothing.
- **Stages.** The setting matters only in `floorplan`. Resuming past `floorplan` restores the grid from the checkpoint.
- **Name.** The variable keeps the "repair channels" name: from the flow's point of view the effect is repair off, and the log says so.
- *Why remove rather than prevent:* repair cannot be turned off (Context). The gap rails reach a macro ring at both ends of every gap row, through the macro grid's `Metal3 Metal1` connect, so the straps add a wall but no connectivity the rings lack. The probe confirmed that, and D2 rechecks it in every run.
- *Alternatives:*
  - Deliberate TopMetal2 pairs per gap: the same walls in chosen places, and an `add_pdn_stripe` cannot be limited to a y range in the core grid.
  - Shifting `tpg2Offset`: see the Non-Goals.

### D2. Connectivity gate when the straps are removed

With repair off, the floorplan runs `check_power_grid -net <net> -dont_require_terminals -error_file <f>` on VDD and VSS before the removal, and again after it, in the same process.

- **Comparison.** Each report's violation type, source and bbox is one entry. The stage fails, before `save_checkpoint basilisk.power_grid`, if any after-entry is missing from the before-set. It logs `Power grid check <net>: ok (<k> pre-existing)` or `failed`, followed by the new entries.
- **Why compare.** Today's grid already fails with 14 reports per net (the west-edge hole in Context), so an absolute gate would always fail. The gate's job is that removal adds nothing, and the probe showed it detects a single added shape.
- **Error handling.** The check raises PSM-0069 whenever any report exists, so each call runs in `catch`, and the result comes from the error files. An error other than PSM-0069, or a missing error file after a raised error, fails the stage.
- **Files.** The four error files go to the report directory (`basilisk_pgcheck_<net>_{before,after}.rpt`), so they are published with the floorplan's reports.
- **Cost.** About 6 minutes under emulation for four checks. Less on the VM.
- **Why only when repair is off.** It keeps the default byte-identical.

### D3. Partial-height TopMetal2 straps are counted

After `pdngen`, an odb walk over the VDD and VSS special wires counts TopMetal2 boxes shorter than the core height minus 1 µm. The floorplan logs `PDN TopMetal2 straps shorter than the core: <n>`. Today's value is 10, and it is 0 with repair off. This is report-only: it runs inside `catch`, and a failure only logs.

### D4. SRAM-end Metal5 hold-back: `PNR_GRT_SRAM_END_METAL5_ADJUST`

- **Parsing.** `common.tcl` parses `pnr_grt_sram_end_metal5_adjust` (empty means 0; a number in [0, 1), checked like the Metal5 hold-back).
- **The strips.** Inside `pnr_apply_sram_metal5_adjustment`'s first-call block, after the footprint regions, each `RM_IHP*` instance gets two Metal5 region adjustments. They are strips `pnr_sram_end_strip_um` = 40 µm deep, inside the footprint, at the bbox's two short ends: west and east when the box is wider than tall, south and north otherwise.
- **Logging.** The proc logs `SRAM-end Metal5 adjustment: <v> over <n> strips (40 um)`.
- **Order with the footprint hold-back.** If the footprint share is 0 and the end share is above 0, the strips are still added. The early return becomes "both are 0".
- **Why 40 µm.** The crossings sit 8–15 µm (D) and 19–24 µm (C) inside the east edges. 40 µm is about six 6.3 µm gcells. It is a constant, not an input, so the dispatch surface grows by one knob per lever.
- **Why both ends of every SRAM.** The rule doesn't depend on orientation or floorplan. Only the east ends of middle-row R180 macros had shorts, but a "bit-0 end" rule would hard-code R180 pin geometry. The measured run reports `grt` overflow, which shows what the extra ends cost.
- **Measured value 0.5.** On top of 0.55, an end strip keeps 0.45 × 0.5 = 22.5 % of Metal5, about 3 of the ~13 tracks per gcell column. That is below the ~5 that clear every power-pad row.
- *Alternative:* a whole-footprint value of 0.70. It was skipped on 2026-10-23 because it adds channel overflow and costs timing over the whole macro, not just where crossings bunch.

### D5. Dispatch inputs

`pnr.yml` gains `pdn_repair_channels` (empty, `0` or `1`) and `sram_end_metal5_adjust`, wired like `sram_metal5_adjust` into `PNR_PDN_REPAIR_CHANNELS` and `PNR_GRT_SRAM_END_METAL5_ADJUST`. That makes 16 inputs, within GitHub's limit of 25.

- `run_pnr.sh`'s header and `docs/pnr-pipeline.md` (the input list, now "sixteen") document both.
- The docs note that `pdn_repair_channels` acts only when `floorplan` runs.

### D6. Measured run and how to read it

After merge, one dispatch on `main`:

- `pdn_repair_channels=0`, `sram_end_metal5_adjust=0.5`, everything else default;
- no resume, so `floorplan` runs (about 12 h, like run A).

Compare against run A (`40081935481`):

- floorplan checks and strap count (expect 0);
- `grt` overflow (7,153) and WNS at `grt` (−12.05 ns);
- the router count and its marker list (8, A–D above);
- antenna nets (8,627);
- `drt` time.

| outcome | next step |
|---|---|
| `floorplan` fails the D2 check | Record which net and where. Repair stays on, and a new change designs per-gap straps. |
| router ≤ 1, nothing at B or D, WNS within 0.5 ns of A | Record it. Propose adopting both settings and requoting, in a follow-up. Optional isolation run (below). |
| B and D clear, C remains | The end hold-back is too weak. Resume from this run's `cts` with `sram_end_metal5_adjust=0.7` (about 9 h). |
| B clears, D remains | The crossing is not routing-driven enough to move. Record it. Next is placement (drivers in the gap), as its own change. |
| router count rises well above 8, or WNS more than 1 ns worse | Record it. Defaults stay. Re-read the marker list before anything else. |

**Optional isolation run (ask first):** resume from the measured run's `cts` with `pdn_repair_channels=0` and `sram_end_metal5_adjust=0` (empty). It separates the PDN switch from the hold-back.

## Risks / Trade-offs

- **[A gap rail is connected only through a ring, which the check misses]** → `check_power_grid` walks the real shapes, so a rail that reaches no ring is reported. The gate is mandatory with repair off.
- **[The removal hits a non-repair shape]** → only straps shorter than the core are selected, and only wires wholly inside them, so a crossing rail is never removed. A wrongly removed shape that leaves others stranded is caught by D2. The probe found exactly Metal5 and TopMetal1 pads under the straps.
- **[The west-edge hole hides a new disconnection inside it]** → it covers 40 × 88 µm at the core's west edge, far from every strap. It is recorded as a follow-up, not fixed here.
- **[IR drop in the gap rows rises]** → the rails there are about 90 µm long and fed from rings at both ends, against a TopMetal2 stub in the middle before. Not analysed. It is listed for the adoption follow-up, before any signoff claim.
- **[The end strips push crossings into the channels, raising `grt` overflow]** → overflow and WNS are in D6's comparison, with a stop row.
- **[`check_power_grid` is slow or memory-heavy at floorplan]** → measured locally in task 1.1, before any VM time.
- **[Removing the stubs moves `gpl` slightly, so other shorts appear]** → D6 reads the full marker list, not only the count.
- **[Resume confusion]** → the switch has no effect on a run resumed past `floorplan`. The floorplan log line is the record, and the docs say so.

## Migration Plan

1. Land D1–D5 with defaults unchanged. Scheduled runs and quoted figures do not move.
2. Run the local gate: run A's `power_grid` checkpoint with the straps removed and checked (task 1.1, done 2026-11-16).
3. Ask, then dispatch D6. Record the result and the probe findings in `docs/infra-plan.md`.
4. Rollback: revert. With both inputs empty the flow is unchanged anyway.
