# Proposal

## Why

The reference run `45035313880` ends detailed routing with 22 router markers (21 shorts, 1 spacing), and a chip with shorts cannot be signed off. Every marker sits where earlier probes already located a cause, and both settings that address those causes are already in the flow. Neither has been measured on its own, and the one run that combined them (`43937159728`) changed placement, CTS depth and WNS together, so nobody adopted them. CTS depth is now stable (`stabilize-cts-tree-depth`), so a clean measurement is possible now.

The 22 markers in `45035313880` (`basilisk_route_drc.rpt`):

| group | count | where | cause (earlier probes) |
| --- | ---: | --- | --- |
| B | 7 | x 7,028–7,033 µm, y 661–669 (6); x 6,147, y 665 (1) | Metal2/Metal4 signal wires crossing the via-stack pads under the channel-repair straps at x 7,030 (VSS) and x 6,150 (VDD) |
| D | 14 | x 6,981–6,994 µm, y 598–658 | Metal5 crossings at the east end of D-cache bank 0, a 180°-rotated SRAM in the middle row, near its `A_DIN[0]` |
| A | 1 | x 486 µm, y 835 | Metal2 short against the core VSS stripe's via pad, just south of the R90 I-cache macro `cut_high` |

## What Changes

- **SRAM end strips on the pin end only.** A new setting lets the existing SRAM-end Metal5 hold-back add its strip only at the one short end of each wider-than-tall SRAM that holds its `A_DIN[0]` pin, instead of at both ends of every SRAM. In `43937159728` the both-ends strips cleared D but pushed routes into A, through the strips at the R90 macros' ends. The default stays "both ends", so runs that leave the new setting empty do not change.
- **A new `pnr.yml` input** for the new setting, which makes 17 inputs.
- **Two measured runs.**
  - Run 1, from `floorplan`: channel-repair straps removed (`pdn_repair_channels=0`), nothing else changed. This measures the strap removal alone, which `clear-sram-corner-router-shorts` task 4.3 never did.
  - Run 2, resumed from run 1's `cts`: adds the pin-end strips. The strips act only at the routing stages, so this isolates them.
- **A local IR-drop comparison** between the grids with and without the straps, which removing them for good needs first.
- **Adoption.** If the runs clear B and D and keep WNS within 0.5 ns of `45035313880`, the defaults change: straps removed, pin-end strips at 0.5. The run with both settings becomes the PPA reference. If they don't, the defaults stay, the result is recorded, and the spec deltas that flip the defaults are dropped before archiving.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pnr-flow`:
  - The SRAM-end Metal5 hold-back gains a pin-end-only mode.
  - On adoption, the channel-repair default becomes "removed", and the end hold-back default becomes 0.5 on the pin end.

## Impact

- **Flow stages:** backend (`floorplan` default; global and detailed routing through `pnr_apply_sram_metal5_adjustment`) and CI (one new `pnr.yml` dispatch input). No RTL, sim, synth or software change.
- **Code:** `target/ihp13/openroad/scripts/pnr/common.tcl`, `target/ihp13/openroad/run_pnr.sh` (header), `.github/workflows/pnr.yml`, `docs/pnr-pipeline.md`, `docs/infra-plan.md`. `scripts/chip.tcl` and `power_grid_stripes.tcl`'s own fallback when it runs outside the staged flow are unchanged.
- **VM time:** about 13 h for run 1 and about 9 h for run 2, each dispatched only after asking.
- **PPA figures:** adoption moves placement, so the quoted PPA must be re-read from run 2. The SHA-3 arm comparison runs need the same defaults on both sides.
