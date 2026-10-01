#!/usr/bin/env python3
# Copyright 2026 Kyiv School of Economics.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
"""Summarise a standalone hw/coproc block synthesis (block-synth.mk).

Reads the yosys `stat -json` area report and `check` report with the synth
lane's own parsers (synth_metrics.py, so cell/area/DFF counting is identical
to the full-SoC lane), plus the block STA report (block_sta.tcl), and writes
one JSON record.

Exits non-zero if yosys `check` found any problem, counting both the final
`check` report and the structural warnings the flow's earlier `check` passes
print to the log (logic loop, conflicting drivers, used-but-undriven wire).
The final report alone is not enough: by the time it runs on the mapped
netlist, earlier passes have resolved loops and undriven nets, so it reports
0 problems for RTL that has them (found with a deliberate negative test,
openspec change sha3-cvxif-coprocessor task 2.6).
"""

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import synth_metrics  # noqa: E402


def parse_block_sta(text):
    """Return (worst slack ns, worst data arrival ns) from block_sta.tcl output."""
    slack = re.search(r"^worst slack(?: max)?\s+(-?[0-9.]+)", text, re.MULTILINE)
    if not slack:
        raise synth_metrics.ReportError("STA report has no 'worst slack' line")
    arrivals = [float(m) for m in re.findall(r"^\s*(-?[0-9.]+)\s+data arrival time", text,
                                             re.MULTILINE)]
    return float(slack.group(1)), (max(arrivals) if arrivals else None)


STRUCTURAL_WARNINGS = re.compile(
    r"^Warning: (found logic loop|multiple conflicting drivers|Wire .* is used but has no driver)",
    re.MULTILINE)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--area", required=True)
    p.add_argument("--check", required=True)
    p.add_argument("--sta", required=True)
    p.add_argument("--log", required=True, help="yosys log of the synthesis run")
    p.add_argument("--period-ns", type=float, required=True)
    p.add_argument("--block", required=True)
    p.add_argument("--rounds-per-cycle", type=int, required=True)
    p.add_argument("--out", required=True)
    a = p.parse_args(argv)

    cells, area, dffs = synth_metrics.parse_area_report(
        synth_metrics.read_report(a.area, "area"))
    problems = synth_metrics.parse_check_report(synth_metrics.read_report(a.check, "check"))
    structural = STRUCTURAL_WARNINGS.findall(Path(a.log).read_text(errors="replace"))
    slack, arrival = parse_block_sta(Path(a.sta).read_text())

    record = {
        "block": a.block,
        "rounds_per_cycle": a.rounds_per_cycle,
        "cells": cells,
        "area_um2": area,
        "dffs": dffs,
        "check_problems": problems,
        "structural_check_warnings": len(structural),
        "clock_period_ns": a.period_ns,
        "worst_slack_ns": slack,
        "critical_path_ns": arrival,
        "kperm_cycles": 24 // a.rounds_per_cycle + 1,
        "corner": "typ_1p20V_25C",
        "stage": "block synthesis (yosys + OpenSTA, no placement)",
    }
    Path(a.out).write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record, indent=2))
    if problems or structural:
        print(f"block_metrics: yosys check reported {problems} problem(s) in the final report "
              f"and {len(structural)} structural warning(s) in the log", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
