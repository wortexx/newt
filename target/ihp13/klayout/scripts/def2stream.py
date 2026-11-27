# Copyright (c) 2018-2023, The Regents of the University of California
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# * Redistributions of source code must retain the above copyright notice, this
#   list of conditions and the following disclaimer.
#
# * Redistributions in binary form must reproduce the above copyright notice,
#   this list of conditions and the following disclaimer in the documentation
#   and/or other materials provided with the distribution.
#
# * Neither the name of the copyright holder nor the names of its
#   contributors may be used to endorse or promote products derived from
#   this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# Originally from OpenROAD-flow-scripts' flow/util/def2stream.py (copied July
# 2023 by upstream Basilisk). Rewritten 2026 by the newt project authors
# (openspec/changes/stream-final-gds, design D1), from the scratch DRC probe's
# stream.py, whose GDS the 2026-11-24/25 signoff DRC ran on, with croc's -rd
# interface (pulp-platform/croc klayout/scripts/def2stream.py).
#
# Streams a routed DEF to GDS: reads the DEF against the LEFs, replaces every
# cell by its geometry from the given GDS files, and writes the top cell.
#
# Run in KLayout batch mode, all inputs as -rd variables (klayout.mk sets them):
#   klayout -b -rd in_def=... -rd lef_files="a.lef b.lef" -rd gds_files="..." \
#     -rd layer_map=src/sg13g2.map -rd design_name=iguana_chip \
#     -rd io_allow='corner|vddpad|...' -rd out_file=out/basilisk.gds.gz \
#     -r scripts/def2stream.py
#
# Exit status: the number of errors (0 = GDS written and every check passed).

import os
import re
import sys
import tempfile
import time

import pya

T0 = time.time()


def log(msg):
    print(f"[{time.time() - T0:7.0f}s] {msg}", flush=True)


def err(msg):
    global errors
    errors += 1
    log(f"ERROR: {msg}")


def rd(name, default=None):
    # -rd variables are globals of this script; a missing one is an error.
    value = globals().get(name, default)
    if value is None:
        log(f"ERROR: missing -rd {name}=...")
        sys.exit(1)
    return value


errors = 0
in_def = rd("in_def")
lef_list = rd("lef_files").split()
gds_list = rd("gds_files").split()
map_file = rd("layer_map")
top_name = rd("design_name")
out_path = rd("out_file")
# Cells allowed to stay empty: an exact-name regex (design D1 step 4). Empty
# means "nothing allowed"; the flow passes the pre-release IO cells.
io_allow = re.compile(rd("io_allow", "") or r"(?!)")

missing = [f for f in [in_def, map_file] + lef_list + gds_list if not os.path.isfile(f)]
for f in missing:
    err(f"input not found: {f}")
if missing:
    sys.exit(errors)

# 1. DEF + LEFs. LEF cells come in as abstracts and are replaced in step 3;
#    the map file decides which DEF geometry becomes mask layers.
opt = pya.LoadLayoutOptions()
cfg = opt.lefdef_config
cfg.lef_files = lef_list
cfg.read_lef_with_def = False
cfg.dbu = 0.001
cfg.map_file = map_file
cfg.read_all_layers = False
for flag in ("produce_obstructions", "produce_blockages", "produce_cell_outlines",
             "produce_placement_blockages", "produce_regions", "produce_lef_pins",
             "produce_lef_labels", "produce_fills"):
    setattr(cfg, flag, False)
for flag in ("produce_routing", "produce_special_routing", "produce_via_geometry",
             "produce_pins", "produce_labels"):
    setattr(cfg, flag, True)

ly = pya.Layout()
log(f"reading DEF {in_def}")
ly.read(in_def, opt)
if not ly.has_cell(top_name):
    err(f"DEF has no cell '{top_name}' (top cells: {[c.name for c in ly.top_cells()]})")
    sys.exit(errors)
top = ly.cell(top_name)
log(f"DEF read: top {top.name}, {ly.cells()} cells")

# 2. Empty every LEF cell, so only its GDS defines it. VIA_* cells are the
#    DEF/LEF vias KLayout generated; they are real geometry and stay.
for c in ly.each_cell():
    if c.cell_index() != top.cell_index() and not c.name.startswith("VIA_"):
        c.clear()

# 3. Merge each GDS. Its own top cells keep their names and bind to the DEF's
#    instances; every other cell in it becomes G<k>_<name>, so a macro's
#    sub-cells can neither replace the DEF's cells (e.g. the delay line's
#    VIA_Via1_YX_so) nor another macro's same-named sub-cells (the SRAMs'
#    RM_IHPSG13_1P_BITKIT_*). Merged through a temporary GDS, as in the probe.
with tempfile.TemporaryDirectory(prefix="def2stream-") as tmpdir:
    for k, path in enumerate(gds_list):
        part = pya.Layout()
        part.read(path)
        tops = {c.cell_index() for c in part.top_cells()}
        renamed = 0
        for c in part.each_cell():
            if c.cell_index() not in tops:
                c.name = f"G{k}_{c.name}"
                renamed += 1
        tmp = os.path.join(tmpdir, f"part{k}.gds")
        part.write(tmp)
        ly.read(tmp)
        log(f"merged {os.path.basename(path)}: {len(tops)} top cells, {renamed} sub-cells renamed G{k}_")

# 4. Drop what the design does not use: every top cell but ours (unused
#    library cells the merges brought in).
extra = [c.cell_index() for c in ly.top_cells() if c.cell_index() != top.cell_index()]
for ci in extra:
    ly.delete_cell_rec(ci)
log(f"dropped {len(extra)} unused top cells")

# 5. Empty-cell check on the cells the DEF instantiates directly. Empty
#    sub-cells deeper down ship that way inside the macros' GDS (the SRAMs'
#    BITKIT_* cells) and are only counted.
def inst_count(cell):
    # Instances of `cell` placed anywhere (arrays counted element by element).
    return sum(pi.child_inst().size() for pi in cell.each_parent_inst())


direct = set(top.each_child_cell())
allowed, missing_gds = [], []
for ci in direct:
    c = ly.cell(ci)
    if c.is_empty():
        (allowed if io_allow.fullmatch(c.name) else missing_gds).append(c)
for c in sorted(allowed, key=lambda c: c.name):
    log(f"empty, allowed (no public GDS): {c.name} x {inst_count(c)}")
log(f"empty allowed cells: {len(allowed)}, instances: {sum(inst_count(c) for c in allowed)}")
for c in sorted(missing_gds, key=lambda c: c.name):
    err(f"cell '{c.name}' ({inst_count(c)} instances) has no geometry in any GDS")
deep_empty = sum(1 for c in ly.each_cell() if c.is_empty() and c.cell_index() not in direct
                 and c.cell_index() != top.cell_index())
log(f"empty macro sub-cells (as shipped, not checked): {deep_empty}")

tops = [c.name for c in ly.top_cells()]
if tops != [top_name]:
    err(f"expected exactly one top cell '{top_name}', got {tops}")

# 6. Write. A .gz suffix makes KLayout compress the stream.
if errors == 0:
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    log(f"writing {out_path}")
    ly.write(out_path)
    log(f"done: {os.path.getsize(out_path)} bytes")
else:
    log(f"{errors} error(s), no GDS written")

sys.exit(errors)
