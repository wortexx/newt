#!/usr/bin/env python3
# Copyright 2026 Kyiv School of Economics.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
"""Sum a per-instance power dump by module (docs/infra-plan.md Phase 17;
openspec change pin-soc-power-activity design D2).

Reads one or more `inst.txt` dumps written by
target/ihp13/openroad/scripts/soc_power_probe.tcl (`report_power -instances`).
OpenROAD links the netlist flat, so modules are recovered from instance names:
the part before the first `/` for cells inside a kept hierarchy (e.g.
`i_iguana_soc.i_keccak_cvxif`), else the first three dotted components for
flattened glue. Prints total and switching power in mW per group, one column
per dump, labelled by the dump's parent directory.

Usage: soc_power_agg.py [--top N] DUMP [DUMP ...]
"""
import argparse
import collections
import os
import sys


def group(name):
    if '/' in name:
        return name.split('/')[0]
    parts = name.lstrip('\\').split('.')
    return '(flat) ' + '.'.join(parts[:3]) if len(parts) > 1 else '(flat top)'


def read_dump(path):
    """Return {group: [switching W, total W]} from one dump."""
    acc = collections.defaultdict(lambda: [0.0, 0.0])
    with open(path) as f:
        for line in f:
            fields = line.split()
            if len(fields) != 5:
                continue
            try:
                _internal, switching, _leakage, total = map(float, fields[:4])
            except ValueError:
                continue  # header lines
            g = acc[group(fields[4])]
            g[0] += switching
            g[1] += total
    return acc


def short(name):
    return name.replace('i_iguana_soc.i_cheshire_soc.', 'soc.').replace('i_iguana_soc.', '')


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--top', type=int, default=25, help='groups to print (default 25)')
    ap.add_argument('dumps', nargs='+')
    args = ap.parse_args(argv)

    labels = [os.path.basename(os.path.dirname(os.path.abspath(p))) or p for p in args.dumps]
    data = [read_dump(p) for p in args.dumps]
    names = set().union(*data)
    rows = sorted(names, key=lambda n: -max(d.get(n, [0, 0])[1] for d in data))

    print(f"{'module (mW: total / switching)':52s}" + ''.join(f'{lb:>22s}' for lb in labels))
    for n in rows[:args.top]:
        print(f'{short(n)[:52]:52s}' + ''.join(
            f'{d.get(n, [0, 0])[1] * 1e3:12.2f} /{d.get(n, [0, 0])[0] * 1e3:8.2f}' for d in data))
    print(f"{'SUM':52s}" + ''.join(
        f'{sum(v[1] for v in d.values()) * 1e3:12.2f} /{sum(v[0] for v in d.values()) * 1e3:8.2f}'
        for d in data))


if __name__ == '__main__':
    main(sys.argv[1:])
