#!/usr/bin/env python3
#
# Copyright 2026 the newt project authors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

"""Check that a yosys netlist still carries the instance and net names the
OpenROAD backend scripts look up by name.

Why this exists
---------------
The backend does not just consume the netlist structurally: `macros.tcl`
places SRAM and delay-line macros by matching literal hierarchical instance
paths ("Macro names as produced by the yosys synthesis", its own comment),
and `basilisk_instances.sdc` anchors most of its timing constraints to
literal cell/net names. A synthesis change that renames things - a yosys
version bump being the obvious one - can leave a netlist that is perfectly
valid, passes `check` with 0 problems, and still silently breaks placement
or drops constraints, because a `get_cells` glob that matches nothing is not
an error in Tcl: it returns an empty collection and the script sails on.

That failure mode is already present in this repo: `*ddr_rcv_clk_o*` matches
nothing in the current netlist, which is why the synth lane reports WNS as
"unavailable" (docs/infra-plan.md Phase 4). It went unnoticed for a long
time. This check makes that class of breakage loud and attributable.

Introduced by openspec/changes/upgrade-yosys-upstream (design D6) as part of
the yosys v0.69 adoption gate.

How patterns are collected
--------------------------
The patterns are parsed out of the backend scripts rather than copied into a
list here, so this check cannot drift away from what the backend actually
matches. From each Tcl file:

  * `set VAR <value>` definitions are collected and `$VAR` references are
    resolved transitively, so a composite path like
    `$CHS_ICACHE.gen_sram.__0.tag_sram...` is checked in full.
  * `get_cells` / `get_nets` glob arguments are collected.
  * Literal names passed to `get_fanin -to` / `get_fanout -from` are
    collected: those anchor a constraint to a specific net just as directly
    as a `get_cells` glob does.

Matching
--------
Globs are translated to regexes with `*` meaning "any run of characters that
are not name separators or Verilog punctuation". Hierarchy separators are
matched loosely: a `.` or `/` in a pattern matches either character. Both
appear, sometimes within one path (`$CHESHIRE.gen_llc.i_llc/i_axi_llc_top_raw`),
because yosys emits `.` for flattened hierarchy and `/` survives from
preserved module instances - and which one applies to a given boundary
depends on YOSYS_KEEP_HIER_INST. Being strict about the separator would
produce false failures that train people to ignore this check, which is
worse than useless.

Exit status is non-zero if any pattern not listed in KNOWN_UNMATCHED has
zero matches. KNOWN_UNMATCHED entries are reported as warnings instead, so a
pre-existing breakage is visible without being attributed to the change
under test - and so that one of them starting to match again is visible too.
"""

import argparse
import os
import re
import sys

# Patterns that already match nothing in the current netlist. Reported as
# warnings, never failures, so this check can be turned on without first
# fixing unrelated pre-existing breakage. Each entry must say why.
KNOWN_UNMATCHED = {
    # basilisk_instances.sdc: `set SLO_PHY_RCLK_REG [get_cells *ddr_rcv_clk_o*]`.
    # The serial-link ddr_rcv_clk_o register is not named this way in the
    # netlist, so the constraints derived from it are silently dropped -
    # this is the root cause of the synth lane's "WNS unavailable"
    # (docs/infra-plan.md Phase 4). Pre-existing content bug, tracked
    # separately; not in scope for the yosys upgrade.
    "*ddr_rcv_clk_o*": "pre-existing: known cause of synth-lane WNS unavailable",
}

# Tcl files whose name lookups the netlist has to satisfy, relative to the
# repository root.
DEFAULT_TCL_SOURCES = [
    "target/ihp13/openroad/src/basilisk_instances.sdc",
    "target/ihp13/openroad/scripts/macros.tcl",
    "target/ihp13/openroad/scripts/macros_2way.tcl",
    "target/ihp13/openroad/scripts/macros_4way.tcl",
]

# `get_pins -of_objects "*_reg" -filter "name == CLK"` in chip.tcl and
# pnr/common.tcl collects the design's clock pins by the `_reg` suffix that
# yosys_synthesis.tcl's `rename -wire -suffix _reg t:*DFF*` puts there. Not
# expressed as a `set`, so it is stated directly.
EXTRA_PATTERNS = [
    ("*_reg", "target/ihp13/openroad/scripts/chip.tcl (clock-pin collection)"),
]

SET_RE = re.compile(r"^\s*set\s+(\w+)\s+(.+?)\s*$", re.MULTILINE)
VAR_RE = re.compile(r"\$(\w+)")
GET_GLOB_RE = re.compile(r"\bget_(?:cells|nets)\s+(?:-\w+\s+)*([^\s\]\[]+)")
FANIN_OUT_RE = re.compile(r"\bget_fan(?:in|out)\s+-(?:to|from)\s+([^\s\]\[]+)")

# A `set` value that names a design object: a hierarchical path or a glob,
# with no Tcl command substitution, list syntax, or whitespace in it.
PATH_LIKE_RE = re.compile(r"^[\w*][\w*./]*$")


def strip_comments(text):
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


def collect_variables(text):
    variables = {}
    for name, value in SET_RE.findall(text):
        variables[name] = value.strip().strip('"')
    return variables


def resolve(value, variables, _depth=0):
    """Expand $VAR references transitively; leave unknown ones intact."""
    if _depth > 10:
        return value

    def sub(match):
        name = match.group(1)
        if name not in variables:
            return match.group(0)
        return resolve(variables[name], variables, _depth + 1)

    return VAR_RE.sub(sub, value)


def collect_patterns(path, text):
    """Return [(pattern, source-description)] for one Tcl file."""
    text = strip_comments(text)
    variables = collect_variables(text)
    found = []

    # Explicit object lookups.
    for regex in (GET_GLOB_RE, FANIN_OUT_RE):
        for raw in regex.findall(text):
            found.append((resolve(raw.strip('"'), variables), path))

    # `set` values that are themselves object paths (how macros.tcl names
    # every SRAM it places).
    for name, value in variables.items():
        resolved = resolve(value, variables)
        if PATH_LIKE_RE.match(resolved) and any(c in resolved for c in "./*"):
            found.append((resolved, f"{path} (${name})"))

    return found


def glob_to_regex(pattern):
    out = []
    for char in pattern:
        if char == "*":
            # Any run of characters that could form part of a name, stopping
            # at Verilog punctuation so a single `*` cannot swallow a whole
            # line and match by accident.
            out.append(r"[^\s,;()\\]*")
        elif char in "./":
            out.append(r"[./]")
        else:
            out.append(re.escape(char))
    return re.compile("".join(out))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("netlist", help="path to the yosys netlist (e.g. out/basilisk.yosys.v)")
    parser.add_argument("--root", default=".", help="repository root the Tcl sources are relative to")
    parser.add_argument("--tcl", action="append", default=None, help="override the Tcl sources to scan (repeatable)")
    args = parser.parse_args(argv)

    if not os.path.isfile(args.netlist):
        print(f"::error::check_netlist_names.py: netlist not found: {args.netlist}", file=sys.stderr)
        return 1
    with open(args.netlist, "r", encoding="utf-8", errors="replace") as f:
        netlist = f.read()

    patterns = []
    for rel in args.tcl or DEFAULT_TCL_SOURCES:
        path = os.path.join(args.root, rel)
        if not os.path.isfile(path):
            print(f"::warning::check_netlist_names.py: Tcl source not found, skipped: {rel}", file=sys.stderr)
            continue
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            patterns.extend(collect_patterns(rel, f.read()))
    patterns.extend(EXTRA_PATTERNS)

    # De-duplicate, keeping the first source seen for each pattern.
    seen = {}
    for pattern, source in patterns:
        if pattern and pattern not in seen:
            seen[pattern] = source

    missing, warned, matched = [], [], 0
    for pattern, source in sorted(seen.items()):
        if glob_to_regex(pattern).search(netlist):
            matched += 1
        elif pattern in KNOWN_UNMATCHED:
            warned.append((pattern, source, KNOWN_UNMATCHED[pattern]))
        else:
            missing.append((pattern, source))

    print(f"checked {len(seen)} name patterns from {len(args.tcl or DEFAULT_TCL_SOURCES)} backend script(s)")
    print(f"  matched: {matched}")
    for pattern, source, why in warned:
        print(f"  KNOWN-UNMATCHED {pattern}  [{source}] - {why}")
        print(f"::warning::netlist name pattern still unmatched (known): {pattern} - {why}", file=sys.stderr)
    for pattern, source in missing:
        print(f"  MISSING         {pattern}  [{source}]")
        print(
            f"::error::netlist has no object matching {pattern!r}, used by {source} - "
            "the backend lookup that depends on it will silently match nothing",
            file=sys.stderr,
        )

    if missing:
        print(f"\nFAIL: {len(missing)} backend name pattern(s) match nothing in this netlist")
        return 1
    print("\nOK: every backend name pattern resolves (known-unmatched ones excepted)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
