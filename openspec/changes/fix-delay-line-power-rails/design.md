# Design

## Context

See proposal.md (Why) for the hole and its mechanism. Measured facts this design relies on:

- **The macro abstract.** `delay_line_D4_O1_6P000` is `CLASS BLOCK`, 39.84 × 41.58 µm. It has six VDD and six VSS pin rails, each 0.44 µm tall and 39.84 µm wide on Metal1 at the core's row pitch. Its obstructions cover all of Metal1 and almost all of Metal2 and Metal3.
- **The floorplan.** `floorplan_ring_4way.tcl` (the lane's floorplan) places both instances R0 at x = `floor_leftX` (388.16 µm), on double-row boundaries, so their pin rails line up with the core's follow-pin rails. `floorplan_ring_2way.tcl` places them at `coreArea_leftX` instead.
- **The gap.** The power-grid checkpoint of run `40081935481` and the final DEF of `43937159728` agree on the geometry. Every core follow-pin rail at the 24 pin heights stops at x 387.72 µm and restarts at 428.44 µm. That leaves a 0.44 µm gap on each side of the macros' 388.16–428.0 µm rails. `basilisk_pdngen.rpt` has no failed via at the macros' heights, so pdngen never tries to connect them from above.
- **Probe, 2026-11-17** (read-only, in the `newt-eda:dev` image, on run `40081935481`'s `basilisk.power_grid`). The probe added one Metal1 `FOLLOWPIN` box over each gap, from the rail's end to the pin rail's edge, touching the pin but not overlapping it. That made 48 boxes: 2 instances × 12 pin rails × 2 sides. `check_power_grid -dont_require_terminals` then reports `PSM-0040 All shapes on net VDD are connected`, and the same for VSS. Before, it reported 14 per net. Abutting shapes count as connected.
- **`pdn_check_net`** (`pdn_repair_straps.tcl`) already wraps `check_power_grid`, tolerates its PSM-0069 error, and returns one entry per report. One check takes about 80–95 s under emulation.

## Goals / Non-Goals

**Goals:**

- Both delay lines connected on VDD and VSS in the floorplan's saved checkpoint, and therefore in every later stage's DEF and GDS.
- A connectivity regression gate on every run from `floorplan`, not only when the channel-repair straps are removed.

**Non-Goals:**

- Generic macro power hookup. The bridge step targets the delay-line master by name. Other `CLASS BLOCK` masters with rail-only supply pins would get their own decision.
- Changing pdngen's trimming of follow-pin rails around blocks.

## Decisions

### D1: Bridge the gap with Metal1 boxes after `pdngen`, abutting the macro

After `pdngen`, a new proc does the following for each instance of `delay_line_D4_O1_6P000`:

- reads each POWER or GROUND MTerm's Metal1 pin boxes, offset by the instance location;
- finds, in the same net's special wires, Metal1 boxes with the same y-span whose end lies within 1 µm outside the pin's x-span on either side;
- adds one `FOLLOWPIN` box on that special wire from the rail's end to the pin's edge.

The boxes abut the pin rail and do not overlap it, so they stay outside the macro's Metal1 obstruction.

Each box is created with an explicit horizontal direction (`$odb::dbSBox_HORIZONTAL`). The first measured run (`44169237604`) created them without one. They survived every ODB checkpoint, and `drt` saw them, but `write_def` silently drops a square special box with an undefined direction. So the routed DEF, which the GDS is streamed from (`klayout/scripts/def2stream.py`), had none of the 48. With the direction set, `write_def` writes each one as an ordinary `FOLLOWPIN` path.

Alternatives considered:

- **A macro PDN grid for the delay line** (`define_pdn_grid -macro -cells delay_line_D4_O1_6P000`) with stripes and connects. The only obstruction-free Metal2/Metal3 columns are 0.38–0.86 µm wide at the macro's edges, too narrow for a via stack. There is nothing for a macro grid to connect to except Metal1.
- **Overlapping bridges, one box per rail across the whole macro (387.72–428.44 µm).** The box would lie over the macro's Metal1 obstruction, and the router might treat it as a short against the blockage. Abutment is enough for connectivity (probe) and does not risk this.
- **Moving the macros under a TopMetal2 stripe.** Stacks cannot land because of the obstructions, wherever the macro is.
- **Tuning pdngen so it does not trim.** The pinned OpenROAD has no setting for its block halo on follow-pins. It would also change rail trimming around every SRAM.

The trim distance is not hard-coded. The 1 µm reach covers today's 0.44 µm gap and future small changes, and stays far below a row's 3.78 µm height, so it cannot reach a rail at another y.

### D2: Fail when a delay-line pin rail is unreachable

The bridge proc fails the stage if a supply pin rail has no same-net core rail within reach on either side. It names the instance and the rail. One side is enough, because a rail connected on the west is connected. Bridges are added on every side where a rail is within reach, so both sides today: two feeds per rail.

Orientation: only R0 (`N`) placements are supported, which is what both ring floorplans use. Any other orientation fails with a message, instead of computing pin positions without the transform. The SWIG `dbTransform::apply` binding is not callable from Tcl in the pinned OpenROAD (the probe's first attempt). An instance count of 0, as with `HYPER_CONF=NO_HYPERBUS`, logs 0 bridges and passes.

### D3: Always-on supply-grid check at the end of the power-grid step

After the bridges and the optional strap removal, `power_grid_stripes.tcl` calls a new proc. It runs `pdn_check_net` on VDD and on VSS with tag `final`, which writes `<proj>_pgcheck_<net>_final.rpt`. It logs `Power grid check <net>: clean`, or `failed (<n> reports)` followed by each entry. If either net failed, it errors before the caller's `save_checkpoint`.

Order inside `power_grid_stripes.tcl`:

1. `pdngen`
2. bridges (D1, D2)
3. strap removal and its before/after gate, if repair is off
4. strap count
5. final check (D3)
6. stripe blockages
7. `reports`, `save`

Because the bridges run first, the removal gate's before-check now sees 0 pre-existing reports. The gate's code and its requirement stay unchanged.

Alternatives considered:

- **Keep the check only on the removal path.** That is what let the hole go unnoticed.
- **Turn on the script's dead `verify` block.** It runs `check_power_grid` without `-dont_require_terminals`. That fails at this stage (no pad terminals before routing, 2026-11-16 probe) and raises an uncaught PSM-0069.

Cost: two checks per run from `floorplan`, about 3 minutes emulated. A run with repair off now makes six checks.

### D4: `chip.tcl` gets the same behaviour

`power_grid_stripes.tcl` is shared, and `chip.tcl` defines `report_dir` and `proj_name`. No guard is needed. The new procs live in `scripts/pdn_delay_line_rails.tcl`, sourced next to `pdn_repair_straps.tcl`. The final check proc goes in `pdn_repair_straps.tcl` next to `pdn_check_net`, so the two check paths share one parser.

### D5: Measured run on lane defaults

One dispatch on `main` from `floorplan`, every input empty. It is compared against `43937159728`, the last full run, made with repair off and the end hold-back at 0.5. It is also compared against `40081935481` (run A, lane defaults), which is the like-for-like reference.

Expected:

- floorplan log: `Delay-line rail bridges: 48`, then both final checks `clean`;
- no router marker inside x 387.0–389.0 or 427.5–429.0 µm, y 4093–4181 µm;
- router markers, `grt` overflow and WNS at `grt` within run-to-run noise of run A. Earlier reruns were byte-identical, so any difference outside the delay-line area is a finding to explain.

If the router flags the bridges, the fallback is to shorten each bridge to one side (west only), then re-measure. Any other drift is recorded as is. The measured run's figures replace run A's as the reference only if they match.

## Risks / Trade-offs

- **[Risk] The router reports a spacing marker between a bridge and the macro's Metal1 obstruction.** They abut, so the spacing is 0. → The measured run checks for markers at the bridges. Fallback: D5. Physically the bridge continues the macro's own rail, so a signoff DRC on the merged GDS sees one continuous rail.
- **[Risk] Abutment connectivity differs between `check_power_grid` and KLayout.** → Both merge touching same-layer shapes. A GDS-level check is outside this change and remains part of signoff.
- **[Risk] The always-on check fails a run that passes today**, because of some other unconnected shape on another floorplan or config. → That is the point of the gate, and the log names the shape. Today's lane config has exactly the 14 reports per net this change removes (probe).
- **[Trade-off] About 3 minutes more per run from `floorplan`.** Negligible against a run of about 12 h.
- **[Trade-off] Resumed runs do not get the fix.** The bridges live in the `power_grid` checkpoint. A run resumed from an older checkpoint keeps the hole. `docs/pnr-pipeline.md` notes this.

## Migration Plan

The change merges on a PR with the local probe evidence, then the D5 run. To roll back, revert the PR. The checkpoints of earlier runs stay valid either way.
