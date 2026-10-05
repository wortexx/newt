#!/usr/bin/env python3
# Copyright 2026 Kyiv School of Economics.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
"""Summarise a hw/coproc block's activity-annotated power run (block-synth.mk
power flow; openspec change sha3-cvxif-coprocessor task 5.2, design D8).

Reads OpenSTA's power.rpt (block_power.tcl: read_saif, then
report_activity_annotation and report_power) and the workload description the
simulation harness wrote. Writes power.json with:
  - the annotated fraction: pins whose activity came from the SAIF, over all
    pins OpenSTA counts (the rest use OpenSTA's propagated activity);
  - total power and its internal / switching / leakage split, and the
    sequential / combinational split, in watts;
  - the workload (blocks, cycles per block, clock period) and the energy per
    block = average power x cycles per block x clock period.
Fails if nothing was annotated: a default-activity number is not workload
power (spec sha3-evaluation).

Usage: block_power_metrics.py --power power.rpt --workload power_workload.json
           --block NAME --rounds-per-cycle R --out power.json
"""

import argparse
import json
import re
import sys
from pathlib import Path

GROUP_RE = re.compile(
    r"^(Sequential|Combinational|Clock|Macro|Pad|Total)\s+"
    r"([-+.\deE]+)\s+([-+.\deE]+)\s+([-+.\deE]+)\s+([-+.\deE]+)")
ANNOTATED_RE = re.compile(r"^Annotated (\d+) pin activities\.")
SOURCE_RE = re.compile(r"^([a-z]+)\s+(\d+)\s*$")


def parse(text):
    groups, sources, annotated = {}, {}, None
    for line in text.splitlines():
        m = GROUP_RE.match(line)
        if m:
            groups[m.group(1)] = {"internal_w": float(m.group(2)), "switching_w": float(m.group(3)),
                                  "leakage_w": float(m.group(4)), "total_w": float(m.group(5))}
            continue
        m = ANNOTATED_RE.match(line)
        if m:
            annotated = int(m.group(1))
            continue
        m = SOURCE_RE.match(line)
        if m:
            sources[m.group(1)] = int(m.group(2))
    return groups, sources, annotated


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--power", required=True)
    ap.add_argument("--workload", required=True)
    ap.add_argument("--block", required=True)
    ap.add_argument("--rounds-per-cycle", type=int, required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)

    groups, sources, annotated = parse(Path(a.power).read_text(errors="replace"))
    if "Total" not in groups:
        sys.exit(f"block_power_metrics: no report_power table in {a.power}")
    unannotated = sources.get("unannotated", 0)
    if annotated is None:
        annotated = sum(v for k, v in sources.items() if k != "unannotated")
    if annotated == 0:
        sys.exit(f"block_power_metrics: no pin activity annotated from the SAIF ({a.power}); "
                 "the power figure would be default activity, not workload power")
    workload = json.loads(Path(a.workload).read_text())
    if workload.get("functional_check") != "PASS":
        sys.exit("block_power_metrics: the workload's functional check did not pass")

    total = groups["Total"]["total_w"]
    period_s = workload["clock_period_ns"] * 1e-9
    record = {
        "block": a.block,
        "rounds_per_cycle": a.rounds_per_cycle,
        "stage": "block synthesis netlist, gate-level simulation (Verilator) + OpenSTA",
        "corner": "typ_1p20V_25C",
        "activity": "annotated from SAIF of the workload below (not default activity)",
        "annotated_pins": annotated,
        "unannotated_pins": unannotated,
        "annotated_fraction": annotated / (annotated + unannotated),
        "power_w": total,
        "internal_w": groups["Total"]["internal_w"],
        "switching_w": groups["Total"]["switching_w"],
        "leakage_w": groups["Total"]["leakage_w"],
        "sequential_w": groups.get("Sequential", {}).get("total_w"),
        "combinational_w": groups.get("Combinational", {}).get("total_w"),
        "workload": workload,
        "energy_per_block_j": total * workload["block_cycles"] * period_s,
    }
    Path(a.out).write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
