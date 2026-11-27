# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Wrap the streamed chip GDS and the seal ring in one top cell (change
# seal-and-drc-gds, design D2; after croc's klayout/scripts/merge_sealring.py).
#
#   klayout -b -rd chip_gds=<basilisk.gds.gz> -rd seal_gds=<seal_ring.gds.gz> \
#              -rd design_name=iguana_chip -rd dx=<um> -rd dy=<um> \
#              -rd out_file=<basilisk.sealed.gds.gz> -r merge_seal.py
#
# Writes top cell <design_name>_sealed: one instance of <design_name> moved by
# (dx, dy) - the seal margin minus the DEF's die origin, so the die sits the
# margin inside the ring - and the ring (sealring_top) at the origin. The
# chip's cells are not touched.

import sys

import pya


def fail(msg):
    # klayout -b swallows sys.exit("text"): no message and exit code 0.
    print(msg, file=sys.stderr)
    sys.exit(1)


def rd(name):
    value = globals().get(name)
    if value in (None, ""):
        fail(f"ERROR: missing -rd {name}=...")
    return value


chip_gds, seal_gds = rd("chip_gds"), rd("seal_gds")
top_name, out = rd("design_name"), rd("out_file")
dx_um, dy_um = float(rd("dx")), float(rd("dy"))

layout = pya.Layout()
layout.read(chip_gds)
tops = [c.name for c in layout.top_cells()]
if tops != [top_name]:
    fail(f"ERROR: {chip_gds}: top cells {tops}, expected exactly [{top_name}]")
chip = layout.cell(top_name)

layout.read(seal_gds)
seal = [c for c in layout.top_cells() if c.name != top_name]
if len(seal) != 1 or seal[0].name != "sealring_top":
    fail(f"ERROR: {seal_gds}: expected one top cell sealring_top, got {[c.name for c in seal]}")

sealed = layout.create_cell(f"{top_name}_sealed")
shift = pya.Vector(int(round(dx_um / layout.dbu)), int(round(dy_um / layout.dbu)))
sealed.insert(pya.CellInstArray(chip.cell_index(), pya.Trans(shift)))
sealed.insert(pya.CellInstArray(seal[0].cell_index(), pya.Trans()))

options = pya.SaveLayoutOptions()
options.write_context_info = False
layout.write(out, options)
print(f"sealed: {sealed.name} = {top_name} moved by ({dx_um}, {dy_um}) um + {seal[0].name}; "
      f"bbox {sealed.dbbox()} -> {out}")
