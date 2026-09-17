#!/usr/bin/env python3
#
# Copyright 2026 the newt project authors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

"""Extract synth-lane metrics (cell count, chip area, DFF count, WNS) from
yosys/OpenSTA reports, compare them against a checked-in baseline, and emit a
Markdown summary table.

Report format reference:

  basilisk_area.json (yosys `stat -json -top <top> -liberty <lib>`):
      {
         "creator": "Yosys 0.69 (...)",
         "invocation": "stat -json -top iguana_chip -liberty ... ",
         "modules": {
            "\\\\some_submodule": { "num_cells": 123, "area": 456.0, ... },
            ...
         },
         "design": {
            "num_cells":         714166,
            "area":              17156844.687500,
            "sequential_area":   4919330.000000,
            "num_cells_by_type": { "sg13g2_dfrbp_1": 89258, ... }
         }
      }

      The top-level "design" key is the whole-hierarchy rollup that yosys
      emits when `-top` is given, so it is the one the lane reports. The
      per-module entries under "modules" are local (this-module-only)
      counts; summing them would double-count, which is exactly the bug the
      old text parser had to work around by scoping to the last
      "=== design hierarchy ===" marker.

      This replaced text-report scraping in the yosys v0.69 upgrade
      (openspec/changes/upgrade-yosys-upstream, design D4): v0.69's `stat`
      prints a table and no longer emits the "Number of cells:" lines the
      old parser matched, while `-json` is a documented structure.

      Note the shape depends on flags: with `-hierarchy`, num_cells becomes
      an object of stringified counts rather than an integer. The flow does
      not pass it; parse_area_report rejects that shape loudly rather than
      silently misreading it.

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

CHECK_RE = re.compile(r"Found and reported (\d+) problems?\.")
SLACK_RE = re.compile(r"^\s*(-?[\d.]+)\s+slack\s+\((?:MET|VIOLATED)\)\s*$", re.MULTILINE)

# Key holding the whole-hierarchy rollup in `stat -json -top <top>` output.
DESIGN_KEY = "design"

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


def _require_number(value, field):
    """Reject the `stat -hierarchy` shape, where counts are objects of strings.

    Without -hierarchy a count is a plain JSON number. With it, yosys emits
    {"count": "714166", "area": "...", "local_count": ...} instead. Reading
    that shape as a number would not raise on its own - it would quietly
    produce a wrong metric - so name the mismatch explicitly.
    """
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ReportError(
            f"'{field}' is {type(value).__name__}, expected a number - the report "
            "looks like it was produced by `stat -json -hierarchy`, which this "
            "parser does not read; regenerate it without -hierarchy"
        )
    return value


def parse_area_report(text):
    # `tee -o` can capture stray yosys log lines (warnings) alongside the
    # JSON, so slice from the first '{' to the last '}' rather than trusting
    # the file to be pure JSON.
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ReportError(
            "area report contains no JSON object - if this is the text "
            "`stat` report (basilisk_area.rpt), pass the `stat -json` one "
            "(basilisk_area.json) instead; the text layout is no longer parsed"
        )
    try:
        report = json.loads(text[start : end + 1])
    except json.JSONDecodeError as e:
        raise ReportError(f"area report is not valid JSON: {e}") from e

    # `stat -json -top <top>` emits a top-level "design" entry holding the
    # whole-hierarchy rollup. Its absence means the report was generated
    # without -top, in which case there is no design-wide total to report
    # and per-module entries would have to be summed (double-counting
    # anything instantiated more than once) - refuse rather than guess.
    if DESIGN_KEY not in report:
        raise ReportError(
            f"area report has no top-level '{DESIGN_KEY}' entry - it was likely "
            "generated without `-top`, so it carries no whole-design rollup"
        )
    design = report[DESIGN_KEY]

    if "num_cells" not in design:
        raise ReportError(f"'{DESIGN_KEY}' entry has no 'num_cells'")
    # yosys omits "area" entirely when no liberty file was loaded (area 0).
    if "area" not in design:
        raise ReportError(
            f"'{DESIGN_KEY}' entry has no 'area' - the report was generated "
            "without a -liberty argument, so no cell areas are known"
        )

    cells = int(_require_number(design["num_cells"], "num_cells"))
    chip_area = float(_require_number(design["area"], "area"))

    by_type = design.get("num_cells_by_type", {})
    if not isinstance(by_type, dict):
        raise ReportError("'num_cells_by_type' is not an object")
    dffs = 0
    for cell_type, count in by_type.items():
        if cell_type.lower().startswith(DFF_PREFIX):
            dffs += int(_require_number(count, f"num_cells_by_type[{cell_type}]"))

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
    parser.add_argument("--area", required=True, help="path to the yosys `stat -json` report (e.g. basilisk_area.json)")
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
