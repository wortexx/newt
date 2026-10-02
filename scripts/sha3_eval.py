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

Rotate share (task 4.5): the core has no bit-manipulation rotates (RVB = 0),
so a 64-bit rotate costs a shift pair plus a combine (3 instructions; 4 for
a variable amount, which also negates the shift count). The baselines'
permutation code is disassembled from the benchmark ELF and those idioms are
counted statically. Each idiom's static count is weighted by how often its
code runs per permutation: once in fully unrolled code; 5 x 24 for the theta
rotate inside a per-column loop and 25 x 24 for the rho rotate inside a
per-lane loop. The result is divided by the measured instructions per block
(the minstret fit slope, one permutation per block). The script also reports
what Zbb's rori/rol would save (2 or 3 instructions per rotate).

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
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ISE_IMPLS = ["ise-kperm", "ise-shatr"]
SW_IMPLS = ["sw-rvcrypto", "sw-xkcp-ref64", "sw-xkcp-opt64"]
MMIO_IMPLS = ["mmio-cpu", "mmio-dma"]  # measured for SHA3-256 only (task 7.1)
CROSSOVER_VARIANT = 256
VARIANTS = [224, 256, 384, 512]
RATE = {224: 144, 256: 136, 384: 104, 512: 72}

# Rotate-share model: per baseline, (function, idiom kind, executions of each
# static idiom per Keccak-f permutation). theta's ROL(C, 1) runs 5 times and
# rho's table-driven ROL 25 times per round in the looped implementations;
# XKCP opt64 is fully unrolled (all 24 rounds in one straight-line function).
ROTATE_MODEL = {
    "sw-rvcrypto": [("KeccakF1600_StatePermute", "const", 5 * 24),
                    ("KeccakF1600_StatePermute", "var", 25 * 24)],
    "sw-xkcp-ref64": [("theta", "const", 5 * 24), ("rho", "var", 25 * 24)],
    "sw-xkcp-opt64": [("KeccakP1600_plain64_Permute_24rounds", "const", 1)],
}
IDIOM_INSTRS = {"const": 3, "var": 4}   # slli+srli+combine; neg+sll+srl+or
ZBB_SAVES = {"const": 2, "var": 3}      # one rori / rol replaces the idiom
ROTATES_PER_PERMUTATION = 24 * (5 + 24)  # theta 5 + rho 24 non-zero offsets

RESULT_RE = re.compile(r"RESULT,(\d+),([a-z0-9-]+),(\d+),(.*)$")
CALIB_RE = re.compile(r"CALIB,(\d+),(\d+)")
MISMATCH_RE = re.compile(r"MISMATCH,(\d+),([a-z0-9-]+),(\d+)")


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
            m = MISMATCH_RE.search(line)
            if m:
                raise EvalError(f"{src}: SHA3-{m.group(1)} {m.group(2)} gave a wrong digest at "
                                f"{m.group(3)} bytes; its timings are not valid")
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


# --- ISE vs MMIO crossover --------------------------------------------------------

def crossovers(fits, max_blocks=10000):
    """Predicted ISE-vs-MMIO crossovers for SHA3-256 (spec "Measured
    ISE-versus-MMIO crossover", task 7.1). For every (ISE, MMIO) pair, both
    split-model costs are evaluated at 1, 2, ... max_blocks permutations, and
    every block count where the cheaper arm changes is reported. Returns
    (ise, mmio, first, switches): `first` is the cheaper arm at one block, and
    `switches` is a list of (blocks, message bytes, newly cheaper arm), where
    bytes is the shortest message with that many permutations."""
    rate = RATE[CROSSOVER_VARIANT]
    out = []
    for ise in ISE_IMPLS:
        for mmio in MMIO_IMPLS:
            fi, fm = fits.get((CROSSOVER_VARIANT, ise)), fits.get((CROSSOVER_VARIANT, mmio))
            if not fi or not fm:
                continue
            def cheaper(n):
                nbytes = (n - 1) * rate
                return mmio if model_cycles(fm, nbytes, rate) < model_cycles(fi, nbytes, rate) \
                    else ise
            first = prev = cheaper(1)
            switches = []
            for n in range(2, max_blocks + 1):
                cur = cheaper(n)
                if cur != prev:
                    switches.append((n, (n - 1) * rate, cur))
                    prev = cur
            out.append((ise, mmio, first, switches))
    return out


# --- Rotate share ----------------------------------------------------------------

def disassemble(elf, objdump):
    """Return {function: [(mnemonic, [operands])]} for the ELF's text."""
    out = subprocess.run([objdump, "-d", str(elf)], check=True, capture_output=True,
                         text=True).stdout
    funcs, cur = {}, None
    for line in out.splitlines():
        m = re.match(r"^[0-9a-f]+ <([^>]+)>:", line)
        if m:
            cur = funcs.setdefault(m.group(1), [])
            continue
        m = re.match(r"\s+[0-9a-f]+:\s+[0-9a-f]+\s+(\S+)\s*(.*)", line)
        if m and cur is not None:
            ops = [x.strip() for x in m.group(2).split("#")[0].split(",") if x.strip()]
            cur.append((m.group(1).removeprefix("c."), ops))
    return funcs


def count_rotate_idioms(ins):
    """Count constant rotates (slli k / srli 64-k of one source) and variable
    rotates (sll / srl of one source by k and by neg(k)) in one function."""
    def src(ops):
        return ops[1] if len(ops) == 3 else ops[0]
    taken, const = set(), 0
    for i, (op, ops) in enumerate(ins):
        if op not in ("slli", "srli") or i in taken:
            continue
        want, k = ("srli" if op == "slli" else "slli"), int(ops[-1], 0)
        for j in range(i + 1, min(len(ins), i + 48)):
            oj, aj = ins[j]
            if j not in taken and oj == want and src(aj) == src(ops) and int(aj[-1], 0) == 64 - k:
                taken |= {i, j}
                const += 1
                break
            if aj and aj[0] == src(ops):
                break
    negs = {ops[0]: ops[1] for op, ops in ins if op in ("neg", "negw") and len(ops) == 2}
    var = 0
    for i, (op, ops) in enumerate(ins):
        if op != "sll" or len(ops) != 3:
            continue
        for oj, aj in ins[max(0, i - 8):i + 8]:
            if oj == "srl" and len(aj) == 3 and aj[1] == ops[1] and negs.get(aj[2]) == ops[2]:
                var += 1
                break
    return {"const": const, "var": var}


def rotate_share(fits, elf, objdump):
    """Rows (impl, rotate instrs/permutation, rotates/permutation, instr/block
    for SHA3-256, share %, Zbb saving %, static idioms) or an error string."""
    if not elf.exists():
        return f"benchmark ELF {elf} not found (build it with make ig-sw-newt)"
    if not shutil.which(objdump):
        return f"{objdump} not found"
    funcs = disassemble(elf, objdump)
    rows = []
    for impl, model in ROTATE_MODEL.items():
        f = fits.get((256, impl))
        if not f:
            continue
        instrs = rotates = saved = 0
        static = []
        for func, kind, weight in model:
            if func not in funcs:
                return f"{impl}: function {func} not in {elf.name}"
            n = count_rotate_idioms(funcs[func])[kind]
            static.append(f"{func}: {n} {kind}")
            instrs += n * IDIOM_INSTRS[kind] * weight
            rotates += n * weight
            saved += n * ZBB_SAVES[kind] * weight
        per_block = f["instret"][1]
        rows.append((impl, instrs, rotates, per_block, instrs / per_block * 100.0,
                     saved / per_block * 100.0, "; ".join(static)))
    return rows


# --- Provenance ------------------------------------------------------------------

def soc_rounds_per_cycle():
    m = re.search(r"KeccakRoundsPerCycle\s*=\s*(\d+)",
                  (REPO / "hw" / "iguana_pkg.sv").read_text())
    return m.group(1) if m else "?"


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


def markdown(calib, fits, rows, prov, rot=None):
    out = io.StringIO()
    p = lambda s="": print(s, file=out)  # noqa: E731
    p("# SHA-3 ISE evaluation: cycles and speedups")
    p()
    p("Generated by `scripts/sha3_eval.py`. Method: RTL simulation of the SoC on the "
      "Xcelium lane (not gem5); `mcycle`/`minstret` around each hash call, minus the "
      "counter-read overhead; warm instruction and data caches; interrupts disabled.")
    p()
    p(f"Configuration: CVA6 `cv64a6_imafdcsclic_sv39`, hypervisor extension on (ADR-0004); "
      f"coprocessor `RoundsPerCycle` = {soc_rounds_per_cycle()} "
      "(`iguana_pkg::KeccakRoundsPerCycle` at generation time; the bundle MANIFEST below "
      "names the source commit).")
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
    xs = crossovers(fits)
    if xs:
        p(f"## ISE vs MMIO accelerator (SHA3-{CROSSOVER_VARIANT})")
        p()
        p("The MMIO accelerator (`hw/coproc/keccak_mmio.sv`) fed by CPU stores (`mmio-cpu`) or by "
          "Cheshire's iDMA (`mmio-dma`), against the ISE back-ends, from the same split-model "
          "fits. A crossover is the shortest message from which the other arm is cheaper (up to "
          "10,000 blocks). Lengths beyond the largest measured message come from the fit and are "
          "marked *EXTRAPOLATED*; task 7.2 brackets each predicted crossover with measured "
          "points.")
        p()
        p("| ISE | MMIO | cheaper at one block | crossover |")
        p("|---|---|---|---|")
        for ise, mmio, first, switches in xs:
            mx = max(fits[(CROSSOVER_VARIANT, ise)]["max_measured_bytes"],
                     fits[(CROSSOVER_VARIANT, mmio)]["max_measured_bytes"])
            if not switches:
                cell = "none in range"
            else:
                cell = "; ".join(f"`{who}` cheaper from {n} blocks (≥ {nb:,} bytes)"
                                 f"{' *EXTRAPOLATED*' if nb > mx else ''}"
                                 for n, nb, who in switches)
            p(f"| {ise} | {mmio} | `{first}` | {cell} |")
        p()
    p("Method differences from arXiv:2508.20653: RTL simulation instead of gem5; "
      "an ASIC flow (IHP SG13G2) instead of an FPGA; the ISE reached through CV-X-IF "
      "instead of an in-pipeline unit. The baselines run on a core without bit-manipulation "
      "rotates (`RVB = 0`); see the rotate-share analysis.")
    p()
    p("## Rotate share of the software baselines")
    p()
    p("The core has no bit-manipulation rotates (`RVB = 0`), so a 64-bit rotate costs a shift "
      "pair plus a combine (3 instructions), or 4 for a variable amount (`neg`, `sll`, `srl`, "
      "`or`). Method: the baselines' permutation code is disassembled from the benchmark ELF "
      "and these idioms are counted statically. Each static idiom is weighted by its executions "
      "per permutation: once in fully unrolled code, 5 × 24 for theta's `ROL(C, 1)` in a "
      "per-column loop, 25 × 24 for rho's table-driven rotate in a per-lane loop. The sum is "
      "divided by the measured instructions per block (the `minstret` fit slope; one "
      "permutation per block). *Zbb saving* is the share Zbb's `rori`/`rol` would remove "
      f"(one instruction per rotate). Keccak-f has {ROTATES_PER_PERMUTATION} non-trivial "
      "rotates per permutation (24 rounds × (5 theta + 24 rho)).")
    p()
    if isinstance(rot, str) or rot is None:
        p(f"Not computed: {rot or 'no ELF given'}.")
    else:
        p("| baseline | rotates/perm | rotate instrs/perm | instr/block (SHA3-256) | "
          "rotate share | Zbb saving | static idioms found |")
        p("|---|---:|---:|---:|---:|---:|---|")
        for impl, instrs, rotates, per_block, share, saving, static in rot:
            p(f"| {impl} | {rotates:,} | {instrs:,} | {per_block:,.0f} | {share:.1f} % | "
              f"{saving:.1f} % | {static} |")
        p()
        p("The looped baselines rotate all 25 lanes in rho, including the offset-0 lane "
          "(a rotate by 0 that still costs the idiom), hence 720 rather than 696.")
        p()
        p("Shares are of dynamic instructions, not cycles: on CVA6 these are single-cycle ALU "
          "operations, while the baselines' cycles per instruction (~2.4 for opt64) are "
          "dominated by loads and stores.")
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
    ap.add_argument("--elf", default=str(REPO / "sw" / "tests" / "sha3_bench.spm.elf"),
                    help="benchmark ELF for the rotate-share analysis")
    ap.add_argument("--objdump", default="riscv64-unknown-elf-objdump")
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
    rot = rotate_share(fits, Path(a.elf), a.objdump)
    (out / f"{a.name}.md").write_text(markdown(calib, fits, table_one(fits), provenance(manifests),
                                               rot))
    print(f"sha3_eval: wrote {out / (a.name + '.md')} and {out / (a.name + '.csv')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
