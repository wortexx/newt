# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Generate IHP's SG13G2 seal ring as a GDS (change seal-and-drc-gds, design D2).
#
#   klayout -b -rd tech_dir=<.../libs.tech/klayout> -rd width=<um> -rd height=<um> \
#              -rd output=<seal_ring.gds.gz> -r seal_ring.py
#
# width/height are the ring's OUTER size in um. The ring comes from the PDK's
# own PCell code (sg13g2_pycell_lib/ihp/sealring_code.py), called directly
# through `cni` without KLayout's PCell registry or `-n sg13g2` - the approach
# of croc's klayout/scripts/generate_seal_ring.py (pulp-platform/croc,
# Apache-2.0), adapted to the sg13g2 PCell library. Top cell: sealring_top.

import importlib.util
import os
import re
import sys
import types

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


tech_dir = rd("tech_dir")
outer_w = float(rd("width"))
outer_h = float(rd("height"))
out_file = rd("output")

py_dir = os.path.join(tech_dir, "python")
pcell_root = os.path.join(py_dir, "sg13g2_pycell_lib")
for path in (pcell_root, os.path.join(py_dir, "pycell4klayout-api", "source", "python")):
    if not os.path.isdir(path):
        fail(f"ERROR: {path} not found - run `make drc-tech`")
sys.path.append(os.path.join(py_dir, "pycell4klayout-api", "source", "python"))

from cni.dlo import PyCellContext  # noqa: E402
from cni.tech import Tech  # noqa: E402

# Load sg13_tech (registers SG13_dev) and sealring_code under a private package
# name, so the library's __init__ (which registers every PCell) never runs.
PKG = "newt_sg13g2_pcell"
for name, path in ((PKG, pcell_root), (f"{PKG}.ihp", os.path.join(pcell_root, "ihp"))):
    module = types.ModuleType(name)
    module.__path__ = [path]
    sys.modules[name] = module


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


load(f"{PKG}.sg13_tech", os.path.join(pcell_root, "sg13_tech.py"))
sealring_code = load(f"{PKG}.ihp.sealring_code", os.path.join(pcell_root, "ihp", "sealring_code.py"))

tech = Tech.get("SG13_dev")
Tech.techInUse = tech.getTechParams()["libName"]
edge_box = float(re.sub("[a-zA-Z]+", "", tech.getTechParams()["sealring_complete_edgeBox"]))

layout = pya.Layout(True)
layout.dbu = 0.001
top = layout.create_cell("sealring_top")
ring = sealring_code.sealring()
ring.setTech(tech)
with PyCellContext(tech, top, ring):
    ring.addCellContext(top)
    ring.setupParams({
        "l": f"{outer_w - 2 * edge_box}u",
        "w": f"{outer_h - 2 * edge_box}u",
        "addLabel": "nil",
        "addSlit": "nil",
        "edgeBox": f"{edge_box}u",
    })
    ring.genLayout()

os.makedirs(os.path.dirname(os.path.abspath(out_file)), exist_ok=True)
options = pya.SaveLayoutOptions()
options.write_context_info = False
layout.write(out_file, options)
bbox = top.dbbox()
print(f"seal ring: requested {outer_w} x {outer_h} um, bbox {bbox} "
      f"({bbox.width()} x {bbox.height()} um), edgeBox {edge_box} um -> {out_file}")
