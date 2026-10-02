#!/usr/bin/env python3
# Copyright 2026 Kyiv School of Economics.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
"""Evaluate SHA-3 benchmark runs (openspec change sha3-cvxif-coprocessor,
spec sha3-evaluation; design D8).

Reads Xcelium-lane results archives (or extracted results directories),
takes the `CALIB` / `RESULT` lines that sw/tests/sha3_bench.spm.c prints over
UART, and for every (variant, implementation):

  - uses a split model. blocks is the number of Keccak-f permutations the
    message costs (floor(len / rate) + 1, the last one carrying the padding).
    A one-block message (len < rate) costs the measured one-block value.
    Longer messages follow cycles = a + b * blocks (and the same for retired
    instructions), fitted by least squares on the points with blocks >= 2.
    The largest residual of that fit is reported as a percentage of the
    measured value, and so is the one-block point's excess over the line.
    Reason: once the ISE's per-block cost fell to ~100-200 cycles, a fixed
    one-off cost of the shortest hash (tens of cycles) put the one-block
    point visibly above an otherwise exact line through the longer messages;
  - produces a table shaped like arXiv:2508.20653 Table I: total cycles over
    the NIST ShortMsg lengths (0..rate bytes) and over the 100 NIST LongMsg
    lengths (2r+1 + k(r+1) bytes), and the speedup of each ISE back-end over
    each software baseline. Totals over lengths beyond the largest measured
    message come from the fit and are marked EXTRAPOLATED.

Provenance is printed with every report: the bundle MANIFEST (source commit,
dirty flag, Bender.lock hash, tool versions), sw/tests/BUILD_INFO (compiler
and flags), and each vendored baseline's REVISION.

Usage:
  scripts/sha3_eval.py RESULTS.tar.gz|DIR [...] --out-dir docs/results [--name sha3-ise]
"""

import argparse
import csv
import io
import re
import sys
import tarfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ISE_IMPLS = ["ise-kperm", "ise-shatr"]
SW_IMPLS = ["sw-rvcrypto", "sw-xkcp-ref64", "sw-xkcp-opt64"]
VARIANTS = [224, 256, 384, 512]
RATE = {224: 144, 256: 136, 384: 104, 512: 72}

RESULT_RE = re.compile(r"RESULT,(\d+),([a-z0-9-]+),(\d+),(.*)$")
CALIB_RE = re.compile(r"CALIB,(\d+),(\d+)")


class EvalError(Exception):
    pass


# --- Input -------------------------------------------------------------------

def read_inputs(paths):
    """Return (list of (source name, run.log text), list of MANIFEST texts)."""
    logs, manifests = [], []
    for p in map(Path, paths):
        if p.is_dir():
            for f in sorted(p.rglob("run.log")):
                logs.append((str(f), f.read_text(errors="replace")))
            for f in sorted(p.rglob("MANIFEST")):
                manifests.append(f.read_text(errors="replace"))
        elif tarfile.is_tarfile(p):
            with tarfile.open(p) as tf:
                for m in tf.getmembers():
                    if m.isfile() and m.name.endswith("run.log"):
                        logs.append((f"{p.name}:{m.name}",
                                     tf.extractfile(m).read().decode(errors="replace")))
                    elif m.isfile() and m.name.endswith("MANIFEST"):
                        manifests.append(tf.extractfile(m).read().decode(errors="replace"))
        else:
            raise EvalError(f"{p}: neither a directory nor a tar archive")
    return logs, manifests


def parse(logs):
    """Return (calib, points) with points[(variant, impl)] = [(bytes, cycles, instret)]."""
    calib, points = None, {}
    for src, text in logs:
        for line in text.splitlines():
            m = CALIB_RE.search(line)
            if m:
                calib = (int(m.group(1)), int(m.group(2)))
            m = RESULT_RE.search(line)
            if not m:
                continue
            variant, impl, rate = int(m.group(1)), m.group(2), int(m.group(3))
            if RATE.get(variant) != rate:
                raise EvalError(f"{src}: SHA3-{variant} reported rate {rate}")
            for field in m.group(4).split(","):
                b, c, i = (int(x) for x in field.split(":"))
                points.setdefault((variant, impl), []).append((b, c, i))
    if not points:
        raise EvalError("no RESULT lines found (did sha3_bench run?)")
    return calib, points


# --- Fits --------------------------------------------------------------------

def blocks(nbytes, rate):
    return nbytes // rate + 1


def fit(xs, ys):
    """Least-squares y = a + b x; returns (a, b, max |residual| / y in %)."""
    n = len(xs)
    if n < 2 or len(set(xs)) < 2:
        raise EvalError("need at least two distinct block counts to fit")
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    a = my - b * mx
    worst = max(abs(y - (a + b * x)) / y * 100.0 for x, y in zip(xs, ys) if y)
    return a, b, worst


def fits_for(points):
    out = {}
    for (variant, impl), pts in sorted(points.items()):
        rate = RATE[variant]
        multi = [p for p in pts if blocks(p[0], rate) >= 2]
        single = [p for p in pts if blocks(p[0], rate) == 1]
        if not single:
            raise EvalError(f"SHA3-{variant} {impl}: no one-block (len < rate) measurement")
        xs = [blocks(b, rate) for b, _, _ in multi]
        f = {
            "cycles": fit(xs, [c for _, c, _ in multi]),
            "instret": fit(xs, [i for _, _, i in multi]),
            "one_block_cycles": sum(c for _, c, _ in single) / len(single),
            "max_measured_bytes": max(b for b, _, _ in pts),
            "points": pts,
        }
        a, b, _ = f["cycles"]
        line = a + b
        f["one_block_excess"] = f["one_block_cycles"] - line
        f["one_block_excess_pct"] = f["one_block_excess"] / f["one_block_cycles"] * 100.0
        out[(variant, impl)] = f
    return out


# --- Table I -------------------------------------------------------------------

def short_lengths(rate):
    return list(range(0, rate + 1))


def long_lengths(rate):
    return [2 * rate + 1 + k * (rate + 1) for k in range(100)]


def model_cycles(f, nbytes, rate):
    """Split model: measured one-block cost, else the fit on blocks >= 2."""
    nb = blocks(nbytes, rate)
    if nb == 1:
        return f["one_block_cycles"]
    a, b, _ = f["cycles"]
    return a + b * nb


def total_cycles(f, rate, lengths):
    total = sum(model_cycles(f, n, rate) for n in lengths)
    extrapolated = max(lengths) > f["max_measured_bytes"]
    return total, extrapolated


def table_one(fits):
    rows = []
    for variant in VARIANTS:
        rate = RATE[variant]
        for impl in ISE_IMPLS + SW_IMPLS:
            f = fits.get((variant, impl))
            if not f:
                continue
            short, short_x = total_cycles(f, rate, short_lengths(rate))
            long_, long_x = total_cycles(f, rate, long_lengths(rate))
            rows.append((variant, impl, short, short_x, long_, long_x))
    return rows


# --- Provenance ------------------------------------------------------------------

def provenance(manifests):
    lines = []
    if manifests:
        head = manifests[0].split("tests:")[0].strip().splitlines()
        lines += ["bundle MANIFEST:"] + ["  " + ln for ln in head]
    else:
        lines += ["bundle MANIFEST: (not in the inputs)"]
    info = REPO / "sw" / "tests" / "BUILD_INFO"
    lines += ["sw build (sw/tests/BUILD_INFO):"]
    lines += ["  " + ln for ln in (info.read_text().splitlines() if info.exists()
                                   else ["(missing - run make ig-sw-newt)"])]
    for rev in sorted((REPO / "sw" / "vendor").glob("*/REVISION")):
        fields = dict(ln.split(":", 1) for ln in rev.read_text().splitlines()
                      if ":" in ln and not ln.startswith(" "))
        lines.append(f"baseline {rev.parent.name}: {fields.get('upstream', '?').strip()} @ "
                     f"{fields.get('commit', '?').strip()}")
    return lines


# --- Output ------------------------------------------------------------------

def write_csv(path, fits):
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["variant", "impl", "bytes", "blocks", "cycles", "instret",
                    "fit_a_cycles", "fit_b_cycles_per_block", "fit_max_residual_pct",
                    "one_block_excess_cycles"])
        for (variant, impl), f in sorted(fits.items()):
            a, b, r = f["cycles"]
            for nb, c, i in f["points"]:
                w.writerow([variant, impl, nb, blocks(nb, RATE[variant]), c, i,
                            f"{a:.1f}", f"{b:.1f}", f"{r:.3f}",
                            f"{f['one_block_excess']:.1f}"])


def markdown(calib, fits, rows, prov):
    out = io.StringIO()
    p = lambda s="": print(s, file=out)  # noqa: E731
    p("# SHA-3 ISE evaluation: cycles and speedups")
    p()
    p("Generated by `scripts/sha3_eval.py`. Method: RTL simulation of the SoC on the "
      "Xcelium lane (not gem5); `mcycle`/`minstret` around each hash call, minus the "
      "counter-read overhead; warm instruction and data caches; interrupts disabled.")
    p()
    if calib:
        p(f"Counter-read overhead subtracted: {calib[0]} cycles, {calib[1]} instructions.")
        p()
    p("## Per-block cost (split model)")
    p()
    p("A one-block message (`len < rate`) costs its measured value. Longer messages follow "
      "`cycles = a + b * blocks`, least-squares fitted on the points with `blocks >= 2`; "
      "*max residual* is that fit's largest deviation from a measured point. *1-block excess* "
      "is how far the measured one-block cost sits above the line (a one-off cost of the "
      "shortest hash that the per-block slope does not carry).")
    p()
    p("| SHA3 | impl | a (cycles) | b (cycles/block) | instr/block | max residual | "
      "1-block (cycles) | 1-block excess |")
    p("|---|---|---:|---:|---:|---:|---:|---:|")
    for (variant, impl), f in sorted(fits.items()):
        a, b, r = f["cycles"]
        p(f"| {variant} | {impl} | {a:,.0f} | {b:,.0f} | {f['instret'][1]:,.0f} | {r:.2f} % | "
          f"{f['one_block_cycles']:,.0f} | {f['one_block_excess']:+,.0f} "
          f"({f['one_block_excess_pct']:+.1f} %) |")
    p()
    p("## Table I (arXiv:2508.20653 form)")
    p()
    p("Total cycles over the NIST ShortMsg lengths (0..rate bytes) and LongMsg lengths "
      "(100 messages, 2r+1 + k(r+1) bytes), from the split model. Cells marked "
      "*EXTRAPOLATED* exceed the largest measured message and come from the fit.")
    p()
    p("| SHA3 | impl | short (cycles) | long (cycles) |")
    p("|---|---|---:|---:|")
    for variant, impl, s, sx, l, lx in rows:
        p(f"| {variant} | {impl} | {s:,.0f}{' *EXTRAPOLATED*' if sx else ''} | "
          f"{l:,.0f}{' *EXTRAPOLATED*' if lx else ''} |")
    p()
    p("### Speedups of the ISE over each software baseline")
    p()
    p("| SHA3 | ISE | baseline | short | long |")
    p("|---|---|---|---:|---:|")
    by = {(v, i): (s, sx, l, lx) for v, i, s, sx, l, lx in rows}
    for variant in VARIANTS:
        for ise in ISE_IMPLS:
            for sw in SW_IMPLS:
                if (variant, ise) in by and (variant, sw) in by:
                    s_i, sx_i, l_i, lx_i = by[(variant, ise)]
                    s_s, sx_s, l_s, lx_s = by[(variant, sw)]
                    p(f"| {variant} | {ise} | {sw} | {s_s / s_i:.2f}x"
                      f"{' *EXTRAPOLATED*' if sx_i or sx_s else ''} | {l_s / l_i:.2f}x"
                      f"{' *EXTRAPOLATED*' if lx_i or lx_s else ''} |")
    p()
    p("Method differences from arXiv:2508.20653: RTL simulation instead of gem5; "
      "an ASIC flow (IHP SG13G2) instead of an FPGA; the ISE reached through CV-X-IF "
      "instead of an in-pipeline unit. The baselines run on a core without bit-manipulation "
      "rotates (`RVB = 0`); see the rotate-share analysis.")
    p()
    p("## Provenance")
    p()
    p("```")
    for ln in prov:
        p(ln)
    p("```")
    return out.getvalue()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+", help="results archives or extracted directories")
    ap.add_argument("--out-dir", default=str(REPO / "docs" / "results"))
    ap.add_argument("--name", default="sha3-ise")
    a = ap.parse_args(argv)
    try:
        logs, manifests = read_inputs(a.inputs)
        calib, points = parse(logs)
        fits = fits_for(points)
    except EvalError as e:
        print(f"sha3_eval: {e}", file=sys.stderr)
        return 1
    out = Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    write_csv(out / f"{a.name}.csv", fits)
    (out / f"{a.name}.md").write_text(markdown(calib, fits, table_one(fits), provenance(manifests)))
    print(f"sha3_eval: wrote {out / (a.name + '.md')} and {out / (a.name + '.csv')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
