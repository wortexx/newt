#!/usr/bin/env python3
#
# Copyright 2026 the newt project authors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

"""Extract synth-lane metrics (cell count, chip area, DFF count, WNS) from
yosys/OpenSTA reports, compare them against a checked-in baseline, and emit a
Markdown summary table.

Report format reference (captured from a real `yosys stat`/`check` run and a
real `sta` `report_checks` run against the newt-eda:dev image, IHP sg13g2
stdcell liberty - see openspec/changes/ci-synth-lane/tasks.md task 1.2/2.1):

  basilisk_area.rpt (yosys `stat -top <top> -liberty <lib>`):
      Number of cells:                714166
        sg13g2_and2_1                 12345
        sg13g2_dfrbp_1                89258
        ...

      Chip area for module '\\iguana_chip': 17156844.687500

  basilisk_synth.rpt (yosys `check`):
      Checking module iguana_chip...
      Found and reported 0 problems.

  STA report_checks output (one block per path group, ending in):
                 4.31   slack (MET)
      or
                -2.50   slack (VIOLATED)

Exit code is non-zero iff the yosys CHECK report shows problems, or a
required report (area or check) is missing/unparseable. A missing or
unparseable STA report degrades WNS to "unavailable" without failing the
job - STA is measurement, not a synth-lane gate (see design.md D4).
"""

import argparse
import json
import os
import re
import sys

CELLS_RE = re.compile(r"Number of cells:\s*(\d+)")
AREA_RE = re.compile(r"Chip area for module '[^']*':\s*([\d.]+)")
CELL_ROW_RE = re.compile(r"^\s{2,}(\S+)\s+(\d+)\s*$")
CHECK_RE = re.compile(r"Found and reported (\d+) problems?\.")
SLACK_RE = re.compile(r"^\s*(-?[\d.]+)\s+slack\s+\((?:MET|VIOLATED)\)\s*$", re.MULTILINE)

# Cells counted as flip-flops for the DFF metric. Matches the Phase 1
# adoption-gate's counting method: any mapped cell whose name starts with
# this prefix. Does not count scan-DFF variants (sg13g2_sdf*) - the flow
# this lane runs does not insert scan chains, so none are expected; if that
# ever changes, this prefix list needs revisiting alongside the baseline.
DFF_PREFIX = "sg13g2_df"


class ReportError(Exception):
    """A required report is missing or could not be parsed."""


def read_report(path, label):
    if not path or not os.path.isfile(path):
        raise ReportError(f"{label} report not found: {path!r}")
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def parse_area_report(text):
    cells_matches = CELLS_RE.findall(text)
    area_matches = AREA_RE.findall(text)
    if not cells_matches or not area_matches:
        raise ReportError(
            "area report did not contain both a cell count and a chip area line"
        )
    cells = int(cells_matches[-1])
    chip_area = float(area_matches[-1])

    dffs = 0
    for line in text.splitlines():
        m = CELL_ROW_RE.match(line)
        if m and m.group(1).lower().startswith(DFF_PREFIX):
            dffs += int(m.group(2))

    return cells, chip_area, dffs


def parse_check_report(text):
    matches = CHECK_RE.findall(text)
    if not matches:
        raise ReportError("check report did not contain a 'Found and reported N problems' line")
    # A multi-module check could in principle print more than one summary
    # line; be conservative and take the worst (max) problem count seen.
    return max(int(m) for m in matches)


def parse_sta_report(text):
    """Return worst slack in ns, or None if no slack line is found."""
    if not text:
        return None
    slacks = [float(m) for m in SLACK_RE.findall(text)]
    return min(slacks) if slacks else None


def fmt(value, unit=""):
    if value is None:
        return "unavailable"
    if isinstance(value, float):
        return f"{value:,.2f}{unit}"
    return f"{value:,}{unit}"


def fmt_delta(current, baseline, unit=""):
    if current is None or baseline is None:
        return "n/a"
    delta = current - baseline
    pct = f" ({100.0 * delta / baseline:+.2f}%)" if baseline else ""
    return f"{delta:+,.2f}{unit}{pct}"


def render_summary(metrics, baseline):
    rows = [
        ("Cell count", metrics["cells"], baseline.get("cells"), ""),
        ("Chip area", metrics["chip_area_um2"], baseline.get("chip_area_um2"), " um^2"),
        ("DFF count", metrics["dffs"], baseline.get("dffs"), ""),
        ("WNS", metrics["wns_ps"], baseline.get("wns_ps"), " ps"),
    ]
    lines = [
        "## Synth lane metrics",
        "",
        f"CHECK problems: **{metrics['check_problems']}**",
        "",
        "| Metric | Current | Baseline | Delta |",
        "| --- | --- | --- | --- |",
    ]
    for name, current, base, unit in rows:
        lines.append(
            f"| {name} | {fmt(current, unit)} | {fmt(base, unit)} | {fmt_delta(current, base, unit)} |"
        )
    lines.append("")
    lines.append(f"Baseline source: {baseline.get('source', 'unknown')} ({baseline.get('date', 'unknown')})")
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--area", required=True, help="path to the yosys stat report (e.g. basilisk_area.rpt)")
    parser.add_argument("--check", required=True, help="path to the yosys check report (e.g. basilisk_synth.rpt)")
    parser.add_argument("--baseline", required=True, help="path to the checked-in baseline JSON")
    parser.add_argument("--sta", help="path to the sta report_checks output (optional)")
    args = parser.parse_args(argv)

    with open(args.baseline, "r", encoding="utf-8") as f:
        baseline = json.load(f)

    try:
        area_text = read_report(args.area, "area")
        check_text = read_report(args.check, "check")
        cells, chip_area, dffs = parse_area_report(area_text)
        check_problems = parse_check_report(check_text)
    except ReportError as e:
        print(f"::error::synth_metrics.py: {e}", file=sys.stderr)
        return 1

    wns_ps = None
    if args.sta:
        try:
            sta_text = read_report(args.sta, "sta")
            wns_ns = parse_sta_report(sta_text)
            if wns_ns is None:
                print("::warning::synth_metrics.py: sta report present but no slack line found - WNS unavailable", file=sys.stderr)
            else:
                wns_ps = wns_ns * 1000.0
        except ReportError as e:
            print(f"::warning::synth_metrics.py: {e} - WNS unavailable", file=sys.stderr)
    else:
        print("::warning::synth_metrics.py: no --sta report given - WNS unavailable", file=sys.stderr)

    metrics = {
        "cells": cells,
        "chip_area_um2": chip_area,
        "dffs": dffs,
        "wns_ps": wns_ps,
        "check_problems": check_problems,
    }

    summary = render_summary(metrics, baseline)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as f:
            f.write(summary)
    else:
        print(summary)

    if check_problems > 0:
        print(f"::error::synth_metrics.py: yosys CHECK reported {check_problems} problem(s)", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
