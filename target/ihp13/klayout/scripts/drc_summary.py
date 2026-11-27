#!/usr/bin/env python3
# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Classify a KLayout DRC report against the IP waiver list (change
# seal-and-drc-gds, design D4).
#
#   drc_summary.py --gds <sealed.gds.gz> --waivers drc-waivers.yaml \
#                  --out drc-summary.txt <report.lyrdb>...
#
# An item is waived only when the waiver list names its rule for the macro it
# lies in. The macro comes from the item's cell: a macro top cell, or a cell
# that only macros matching one waiver pattern contain. Items reported in a
# cell outside every macro (the top, standard cells, the seal ring) are placed
# by location: inside a macro instance's box counts as that macro. Exit 1 when
# any item is not waived or the waiver list names a rule the report does not
# define; exit 2 on bad input.

import argparse
import collections
import fnmatch
import sys

import klayout.db as db
import klayout.rdb as rdb
import yaml

MAX_LOCATIONS = 20


def load_waivers(path):
    with open(path) as f:
        data = yaml.safe_load(f) or {}
    waivers = data.get("waivers") or []
    for i, w in enumerate(waivers):
        for key in ("cells", "rules", "reason", "evidence"):
            if not w.get(key):
                sys.exit(f"ERROR: {path}: waiver {i} has no '{key}'")
    return waivers


def macro_map(layout, patterns):
    """Cell index -> set of macro top-cell names that contain it (or are it)."""
    owners = collections.defaultdict(set)
    macros = [c for c in layout.each_cell()
              if any(fnmatch.fnmatchcase(c.name, p) for p in patterns)]
    for m in macros:
        owners[m.cell_index()].add(m.name)
        for ci in m.called_cells():
            owners[ci].add(m.name)
    return owners, {m.cell_index() for m in macros}


def macro_boxes(layout, cell, macro_ids):
    """(DBox, macro name) for every macro instance under `cell`, in its coordinates."""
    boxes = []
    it = db.RecursiveInstanceIterator(layout, cell)
    it.targets = list(macro_ids)
    while not it.at_end():
        child = it.inst_cell()
        trans = it.trans() * it.current_inst_element().specific_cplx_trans()
        boxes.append((child.bbox().transformed(trans).to_dtype(layout.dbu), child.name))
        it.next()
    return boxes


def item_box(item):
    box = db.DBox()
    for v in item.each_value():
        for kind in ("box", "polygon", "edge_pair", "edge", "path"):
            if getattr(v, f"is_{kind}")():
                box += getattr(v, kind)().bbox()
                break
    return box


def main():
    ap = argparse.ArgumentParser(description="Classify a KLayout DRC report against the IP waiver list.")
    ap.add_argument("--gds", required=True)
    ap.add_argument("--waivers", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("reports", nargs="+")
    args = ap.parse_args()

    waivers = load_waivers(args.waivers)
    patterns = [p for w in waivers for p in w["cells"]]

    layout = db.Layout()
    layout.read(args.gds)
    owners, macro_ids = macro_map(layout, patterns)
    box_cache = {}

    def waiver_rules(macros):
        rules = set()
        for w in waivers:
            if macros and all(any(fnmatch.fnmatchcase(m, p) for p in w["cells"]) for m in macros):
                rules.update(w["rules"])
        return rules

    defined = set()
    total = collections.Counter()
    waived = collections.Counter()
    hits = collections.defaultdict(collections.Counter)      # rule -> where -> n
    open_items = collections.defaultdict(list)                # rule -> [(cell, box)]
    for path in args.reports:
        report = rdb.ReportDatabase("")
        report.load(path)
        for cat in report.each_category():
            defined.add(cat.name())
        for item in report.each_item():
            rule = report.category_by_id(item.category_id()).name().strip("'")
            cell_name = report.cell_by_id(item.cell_id()).name()
            n = 1
            total[rule] += n
            cell = layout.cell(cell_name)
            macros = owners.get(cell.cell_index(), set()) if cell else set()
            box = item_box(item)
            if not macros and cell is not None:
                if cell_name not in box_cache:
                    box_cache[cell_name] = macro_boxes(layout, cell, macro_ids)
                macros = {name for b, name in box_cache[cell_name]
                          if not box.empty() and b.contains(box.p1) and b.contains(box.p2)}
            where = "/".join(sorted(macros)) if macros else f"design ({cell_name})"
            hits[rule][where] += n
            if rule in waiver_rules(macros):
                waived[rule] += n
            else:
                open_items[rule].append((cell_name, box))

    defined = {d.strip("'") for d in defined}
    unknown = sorted({r for w in waivers for r in w["rules"]} - defined)
    not_waived = sum(total[r] - waived[r] for r in total)

    lines = [f"DRC summary: {', '.join(args.reports)}",
             f"GDS: {args.gds}", f"waivers: {args.waivers}", "",
             f"{'rule':<22}{'total':>12}{'waived':>12}{'not waived':>12}  where"]
    for rule in sorted(total, key=lambda r: (-total[r], r)):
        where = ", ".join(f"{w} {n}" for w, n in hits[rule].most_common())
        lines.append(f"{rule:<22}{total[rule]:>12}{waived[rule]:>12}"
                     f"{total[rule] - waived[rule]:>12}  {where}")
    for rule in sorted(open_items):
        lines.append("")
        lines.append(f"not waived: {rule} ({len(open_items[rule])} items), first {MAX_LOCATIONS}:")
        for cell_name, box in open_items[rule][:MAX_LOCATIONS]:
            lines.append(f"  {cell_name} {box}")
    lines.append("")
    for w in waivers:
        for rule in w["rules"]:
            found = sum(n for where, n in hits[rule].items()
                        if any(fnmatch.fnmatchcase(where, p) for p in w["cells"]))
            if not found:
                lines.append(f"waiver unused: {rule} in {', '.join(w['cells'])}")
    for rule in unknown:
        lines.append(f"waiver names an unknown rule: {rule}")
    lines.append(f"non-waived: {not_waived}")

    text = "\n".join(lines) + "\n"
    with open(args.out, "w") as f:
        f.write(text)
    sys.stdout.write(text)
    return 1 if not_waived or unknown else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as exc:  # a crash is "bad input" (2), never "violations" (1)
        print(f"ERROR: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(2)
