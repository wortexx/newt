# Design

## Context

See proposal.md (Why) for the 22 markers and their groups. Current state:

- **Channel-repair straps.** pdngen adds 10 partial-height TopMetal2 straps. Eight sit in the 90 µm gaps between macros in the bottom and middle rows: VSS at x 2,106, 5,298 and 7,030, VDD at 6,150, and so on. OpenROAD `2c56926971` cannot turn the repair off. `PNR_PDN_REPAIR_CHANNELS=0` (`pdn_repair_straps.tcl`, `clear-sram-corner-router-shorts` D1/D2) removes the straps and their via stacks after pdngen. It runs `check_power_grid` on both nets before and after the removal, and fails the floorplan if anything new is disconnected. Default 1 (keep). `power_grid_stripes.tcl` falls back to 1 when `common.tcl` is not sourced (`scripts/chip.tcl`).
- **SRAM end strips.** `pnr_apply_sram_metal5_adjustment` (`common.tcl`) adds the whole-footprint Metal5 hold-back (0.55). When `PNR_GRT_SRAM_END_METAL5_ADJUST` > 0 (default 0), it adds a 40 µm strip at both short ends of every `RM_IHP*` instance. The proc is called only through `pnr_apply_routing_layers`, in `grt`, `grt_repair`, `ant` and `drt`, so the strips never affect placement or CTS.
- **What the one combined run showed** (`43937159728`, straps removed plus strips 0.5 at both ends):
  - B, C and D cleared.
  - A grew from 1 to 6 markers. Signal-wire counts in the DEF trace this to the south-end strip of the R90 I-cache macro `cut_high`.
  - WNS at `grt` was 1.28 ns worse than run A's. That run could not tell how much came from the strips and how much from the placement shift the strap removal causes, and CTS depth was not yet stable.
- **SRAM pins.** Every SRAM master in the PDK (`RM_IHPSG13_1P_{64,256,1024}x64_c2_bm_bist`, 784.48 µm wide) has its signal pins on the `y = 0` long edge, with `A_DIN[0]` 3.29 µm from x = 0. So on a horizontal macro the bit-0 end is the west end at R0 and the east end at R180. On an R90 macro, which is taller than wide, the pins lie along a long vertical edge, and an end strip there sits across the pin row, which is what happened at A.
- **Determinism.** Runs with the same inputs reproduce through `cts` byte for byte (`44708127322` and `45035313880` have identical `dpl` reports, and the CTS reruns matched). So a run resumed from another run's `cts` with only routing settings changed equals a fresh run with those settings.
- **IR drop.** `analyze_power_grid` in the image supports `-source_type STRAPS`, which feeds each net from its top-layer stripes. The flow has never run it.

## Goals / Non-Goals

**Goals:**

- Measure each setting on its own, against `45035313880`, with CTS depth no longer adding noise.
- Strips only where crossings bunch: the bit-0 end of horizontal SRAMs. None on the R90 macros' pin rows.
- Adopt both as defaults if they clear B and D at a WNS cost of 0.5 ns or less, and quantify what removing the straps costs in IR drop first.

**Non-Goals:**

- Marker A on its own. It is one short against a core-stripe via pad. If it stays after run 2, it is recorded with its nets, and a fix is a separate change.
- More detailed-routing iterations. `45035313880` sat at 44 markers from iteration 21 to 27, and only the last iteration reached 22.
- Antenna, metal fill, the IO ring (scoped out by the user).
- Changing `scripts/chip.tcl` or the power grid's stripe pitch (`clear-sram-corner-router-shorts` Non-Goals).

## Decisions

### D1. End choice: `PNR_GRT_SRAM_END_SIDES` (`both` | `pin`)

- `common.tcl` parses it next to `PNR_GRT_SRAM_END_METAL5_ADJUST`. Empty means `both` until adoption (D6). Any other value raises an error naming the variable, before routing.
- **`pin`:**
  - For each `RM_IHP*` instance wider than tall, the strip goes at the short end nearest the centre of its `A_DIN[0]` pin shape (instance terminal bbox): west if the pin's x is below the macro's centre, east otherwise.
  - Instances taller than wide get no strip.
  - An instance with no `A_DIN[0]` terminal fails the stage, naming the instance and master. Every master in the design has one, so a missing pin means a new master that needs a decision.
- **Log:** `SRAM-end Metal5 adjustment: <v> over <n> strips (40 um, <both|pin> end)`. The `both` line keeps today's text with `both end` appended.
- *Why the pin, not the orientation:* the pin location covers R0, R180 and the mirrored forms without a table, and stays right if the floorplan changes an orientation.
- *Why no strips on vertical macros:* that's where `43937159728` grew A. None of the 22 markers is at a vertical macro's end.
- *Alternative: a list of instance names.* Rejected, since it breaks on every floorplan edit.

### D2. Dispatch input `sram_end_sides`

`pnr.yml` gains `sram_end_sides` (empty, `both` or `pin`), wired into `PNR_GRT_SRAM_END_SIDES` like `sram_end_metal5_adjust`. That makes 17 inputs, within GitHub's 25. `run_pnr.sh`'s header and `docs/pnr-pipeline.md` (the input list, now "seventeen") document it.

### D3. IR-drop comparison before any VM time

A scratch script loads `45035313880`'s `cts` checkpoint and runs `analyze_power_grid -net <VDD|VSS> -corner tt -source_type STRAPS` with the flow's uniform activity (`set_power_activity -global -activity 0.1 -duty 0.5`). It then removes the straps with `pdn_remove_repair_straps_checked`, in the same process, and runs the analysis again. Same placement and cells, only the grid differs.

- It records the worst drop per net, and the worst drop inside the eight gap windows (x ± 45 µm around each strap, over the strap's y span), before and after.
- **Gate:** the worst drop per net does not rise by more than 10 % or 5 mV, whichever is larger. Beyond that, ask the user before dispatching. The absolute values are recorded either way, since the thesis has no IR-drop figure yet.
- *Why `STRAPS`:* the flow has no bump or pad voltage-source file. `STRAPS` feeds the grid from its TopMetal2 stripes, the same model for both grids, so the difference is meaningful even if the absolute number is optimistic.

### D4. Local global-routing check of the pin-end strips

The same checkpoint, loaded with `pnr_apply_routing_layers` and pin-end strips at 0.5, runs `global_route` and writes guides. This is compared with the run's own guides (strips 0):

- the strips' list, one per horizontal macro, with the end chosen (expect east on R180 and west on R0);
- `grt` overflow;
- Metal5 guide segments in the D window (D-cache bank 0's east 40 µm) and the A window (30 × 30 µm at x 478–508, y 815–845).

This checks the geometry and the direction of the effect without a 9 h run. It does not predict the router count.

### D5. Two measured runs

| run | how | settings | measures |
| --- | --- | --- | --- |
| 1 | `main`, from `floorplan` | `pdn_repair_channels=0` | strap removal alone (B) |
| 2 | resume from run 1, `resume_exclude=grt grt_repaired ant_jumper ant drt final` | as run 1, plus `sram_end_metal5_adjust=0.5 sram_end_sides=pin` | pin-end strips alone (D, A) |

Each is compared with `45035313880` and with the other. The comparison covers floorplan strap count and power-grid checks, WNS/TNS at `grt`, `grt` overflow, the full marker list by group, antenna nets, clock and total power, area and `drt` time.

| outcome | next step |
| --- | --- |
| Run 1: B remains | Record the nets. Strap removal does not clear B. Stop before run 2 and ask. |
| Run 1: B clear, WNS more than 0.5 ns worse than `45035313880` | Record it. Ask before run 2, since adoption would then rest on a placement-shift cost. |
| Run 2: no marker at B or D, at most 2 in all, WNS within 0.5 ns of `45035313880` | Adopt (D6). |
| Run 2: D remains | Ask about a resume from run 1's `cts` at 0.7 (about 9 h). |
| Run 2: A grows beyond 2 | Record the window counts as in `43937159728`. Defaults stay. |

### D6. Adoption: defaults flip in `common.tcl`

If D5 says adopt:

- `PNR_PDN_REPAIR_CHANNELS` empty means 0 in `common.tcl`. `power_grid_stripes.tcl`'s own fallback stays 1, so `chip.tcl` is unchanged.
- `PNR_GRT_SRAM_END_METAL5_ADJUST` empty means 0.5, and `PNR_GRT_SRAM_END_SIDES` empty means `pin`.
- `pnr.yml`'s input descriptions and `docs/pnr-pipeline.md` name the new defaults.
- **No confirmation run.** By the determinism in Context, run 2 is what a fresh run on the new defaults gives. Run 2 becomes the PPA and router reference, and the signoff DRC probe is re-run on its DEF.

If D5 says don't adopt, the defaults stay, and the two MODIFIED requirements' default clauses are reverted in the delta before archiving. The pin-end mode stays as an option.

## Risks / Trade-offs

- **[Removing the straps raises IR drop in the gap rows]** → D3 measures it on the same placement before any run, with a gate.
- **[Removing the straps moves placement, so new markers appear elsewhere]** → run 1 reads the full marker list, and the CTS rule keeps the clock tree from adding its own noise.
- **[`STRAPS` sources understate absolute IR drop]** → only the difference is gated; the absolute values are recorded as indicative.
- **[The floorplan's four `check_power_grid` calls become a default cost]** → minutes per run on the VM, small next to a 13 h run.
- **[A pin on a corner, or a master whose `A_DIN[0]` sits mid-edge]** → the nearest-end rule still picks one end. A missing pin fails the stage, so it can't pass silently.
- **[Determinism doesn't hold through the resume]** → run 2's restored `cts` checkpoint is run 1's own, so run 2 is exactly "run 1 plus strips" either way. Only the no-confirmation-run claim in D6 depends on determinism, and the next scheduled or dispatched run on the defaults tests it.

## Migration Plan

1. Land D1–D2 with defaults unchanged. Runs with empty inputs are byte-identical to today.
2. Local checks D3 and D4.
3. Ask, then dispatch run 1. Ask, then dispatch run 2.
4. Adopt (D6) on its own branch after the record, or record and keep the defaults.
5. Rollback: dispatch with `pdn_repair_channels=1 sram_end_metal5_adjust=0`, or revert the default commit.
