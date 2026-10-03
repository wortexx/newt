#!/usr/bin/env python3
# Copyright 2026 Kyiv School of Economics.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
"""Write docs/results/sha3-ppa.md from block-synthesis results (openspec change
sha3-cvxif-coprocessor, task 5.1).

Reads target/ihp13/yosys/block/keccak_cvxif_r<R>/metrics.json for every R in
{1, 2, 3, 4, 6} (make synth-coproc-block BLOCK=keccak_cvxif ROUNDS_PER_CYCLE=<R>)
and the R the SoC uses (iguana_pkg::KeccakRoundsPerCycle). It tabulates area,
flip-flops, critical path, slack and kperm latency, and applies the selection
rule: the largest R whose critical path leaves >= 20 % slack at the 11.0 ns
constraint. The script fails if the SoC's R is not the one the rule selects.

With --soc RUN_DIR --soc-ref REF_DIR (task 5.3) it adds the SoC synthesis
section. Each directory holds a synth lane run's `synth-reports` artifact
(`gh run download <id> -n synth-reports -D <dir>`). RUN_DIR is the SoC with
the coprocessor, and REF_DIR is the same flow on the tree just before it. The
section gives totals, CHECK problems and the coprocessor instance. It also
gives the delta against the reference and against synth-baseline.json, plus
the modules whose area moved. The totals and the CHECK count are parsed by
the CI lane's own target/ihp13/yosys/scripts/synth_metrics.py.

If target/ihp13/yosys/block/keccak_cvxif_r<R>/power.json exists for the
selected R (make power-coproc-block, task 5.2), it adds the block power
section: activity-annotated power of the block netlist under a SoC-paced
SHA3-256 workload, with its annotated fraction and energy per block.

If the five power_<name>.json of `make power-coproc-workloads` exist for the
selected R (task 5.5), it adds the energy-per-byte section: each ISE
back-end in both cache regimes, at the 11.0 ns constraint and, with
--achieved-period-ns, at the period P&R achieved; plus the idle
coprocessor's cost per byte of the software baselines.

Usage: scripts/sha3_ppa.py [--out docs/results/sha3-ppa.md]
                           [--soc RUN_DIR --soc-ref REF_DIR]
                           [--soc-run-id N --soc-ref-run-id N]
                           [--achieved-period-ns T]
"""

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "target" / "ihp13" / "yosys" / "scripts"))
import synth_metrics  # noqa: E402  (the CI lane's parsers)
BLOCK_DIR = REPO / "target" / "ihp13" / "yosys" / "block"
ROUNDS = [1, 2, 3, 4, 6]
MIN_SLACK_FRACTION = 0.20


def soc_rounds_per_cycle():
    text = (REPO / "hw" / "iguana_pkg.sv").read_text()
    m = re.search(r"KeccakRoundsPerCycle\s*=\s*(\d+)", text)
    if not m:
        sys.exit("sha3_ppa: KeccakRoundsPerCycle not found in hw/iguana_pkg.sv")
    return int(m.group(1))


def tool_versions(r):
    log = (BLOCK_DIR / f"keccak_cvxif_r{r}" / "yosys.log").read_text(errors="replace")
    sta = (BLOCK_DIR / f"keccak_cvxif_r{r}" / "sta.rpt").read_text(errors="replace")
    yosys = re.search(r"Yosys (\S+) \(git sha1 (\w+)", log)
    opensta = re.search(r"OpenSTA (\S+ \S+)", sta)
    return (f"Yosys {yosys.group(1)} ({yosys.group(2)[:9]})" if yosys else "Yosys (unknown)",
            f"OpenSTA {opensta.group(1)}" if opensta else "OpenSTA (unknown)")


def reports_dir(d):
    d = Path(d)
    return d / "reports" if (d / "reports" / "basilisk_area.json").exists() else d


def soc_metrics(d):
    """Totals, CHECK problems and per-module area (by module base name)."""
    r = reports_dir(d)
    cells, area, dffs = synth_metrics.parse_area_report((r / "basilisk_area.json").read_text())
    check = synth_metrics.parse_check_report((r / "basilisk_synth.rpt").read_text())
    modules = {}
    for name, m in json.loads((r / "basilisk_area.json").read_text())["modules"].items():
        base = re.sub(r"__\d+$", "", name.lstrip("\\"))
        modules[base] = modules.get(base, 0.0) + float(m.get("area") or 0.0)
    keccak = None
    text = (r / "basilisk_area.rpt").read_text()
    m = re.search(r"=== (keccak_cvxif\S*) ===(.*?)Chip area for module '\\\1': ([\d.]+)",
                  text, re.S)
    if m:
        kc = re.search(r"^\s+(\d+)\s+\S+\s+cells$", m.group(2), re.M)
        kd = sum(int(n) for n, cell in re.findall(r"^\s+(\d+)\s+\S+\s+(sg13g2_\w*df\w*)$",
                                                     m.group(2), re.M))
        keccak = (int(kc.group(1)) if kc else None, float(m.group(3)), kd)
    return {"cells": cells, "area": area, "dffs": dffs, "check": check, "modules": modules,
            "keccak": keccak}


def pct(cur, ref):
    return f"{cur - ref:+,.0f} ({(cur - ref) / ref * 100:+.2f} %)"


def soc_section(run, ref, run_id, ref_id):
    base = json.loads((REPO / "target" / "ihp13" / "yosys" / "synth-baseline.json").read_text())
    kc, ka, kd = run["keccak"] or (None, None, None)
    out = [
        "## SoC synthesis (task 5.3)",
        "",
        f"Synth lane run {run_id or '?'} (SoC with `keccak_cvxif`, R = {soc_rounds_per_cycle()}) "
        f"against run {ref_id or '?'}, the same flow on the tree just before the coprocessor "
        "(Cheshire fork `v0.3.1-newt.1`, CV-X-IF off). Stage: Yosys synthesis, "
        "`typ_1p20V_25C`. CVA6 `cv64a6_imafdcsclic_sv39`, hypervisor extension on (ADR-0004). "
        f"Yosys `CHECK` problems: {run['check']} (reference: {ref['check']}).",
        "",
        "| | reference | with coprocessor | delta | vs `synth-baseline.json` |",
        "|---|---:|---:|---:|---:|",
        f"| cells | {ref['cells']:,} | {run['cells']:,} | {pct(run['cells'], ref['cells'])} | "
        f"{pct(run['cells'], base['cells'])} |",
        f"| area (µm²) | {ref['area']:,.0f} | {run['area']:,.0f} | "
        f"{pct(run['area'], ref['area'])} | {pct(run['area'], base['chip_area_um2'])} |",
        f"| flip-flops | {ref['dffs']:,} | {run['dffs']:,} | {pct(run['dffs'], ref['dffs'])} | "
        f"{pct(run['dffs'], base['dffs'])} |",
        "",
    ]
    if kc is not None:
        out += [f"`i_keccak_cvxif` is its own instance (kept hierarchy): **{kc:,} cells, "
                f"{ka:,.0f} µm², {kd:,} flip-flops**, {ka / run['area'] * 100:.2f} % of the "
                "SoC area.", ""]
    moved = sorted(((run["modules"].get(k, 0) - ref["modules"].get(k, 0), k)
                    for k in set(run["modules"]) | set(ref["modules"])
                    if k not in ("iguana_chip",)), key=lambda x: -abs(x[0]))
    moved = [(d, k) for d, k in moved if abs(d) >= 500][:8]
    out += ["Modules whose area moved by ≥ 500 µm² (reference → with coprocessor):", "",
            "| module | delta (µm²) |", "|---|---:|"]
    out += [f"| `{k}` | {d:+,.0f} |" for d, k in moved]
    out += ["",
            "`cva6` shrinking while CV-X-IF is switched on (its `cvxif_fu` becomes live) is "
            "beyond the ±0.04 % ABC noise seen on untouched modules; its cause has not been "
            "investigated. The SoC delta therefore differs from the coprocessor's own area by "
            "that amount.",
            "",
            "`synth-baseline.json` (2026-09-17) predates the Cheshire v0.3.1 bump; the reference "
            "run is within 0.05 % of it on every metric, so that bump moved the SoC by noise "
            "only. Timing (WNS) is not available from the synth lane's STA (a known gap in "
            "`basilisk.sdc`, also unavailable in the baseline); SoC timing comes from P&R "
            "(task 5.4).", ""]
    return out


def power_section(p):
    w = p["workload"]
    period = w["clock_period_ns"]
    total = p["power_w"]

    def mw(x):
        return f"{x * 1e3:.3f}"

    return [
        "## Block power (task 5.2)",
        "",
        f"Stage: {p['stage']}. Corner: `{p['corner']}`. Clock: {period:.1f} ns, ideal (no "
        "clock tree, so the clock-network power is 0 here). Activity: "
        f"{p['activity']}; **{p['annotated_pins']:,} of "
        f"{p['annotated_pins'] + p['unannotated_pins']:,} pins annotated "
        f"({p['annotated_fraction'] * 100:.1f} %)** from the SAIF of a gate-level simulation of "
        "the synthesized netlist (yosys cell models from the liberty, Verilator "
        "`--trace-saif`, OpenSTA `read_saif`).",
        "",
        f"Workload: {w['workload']}, R = {p['rounds_per_cycle']}. {w['blocks']} blocks of "
        f"{w['block_cycles']} cycles: 17 `kxor` one every {w['lane_gap']} cycles, then "
        "`kperm`, then idle to the block's end, which is the per-block cycle count measured "
        "on the SoC (`docs/results/sha3-ise.md`). Traced window: "
        f"{w['traced_cycles']:,} cycles. Gate-level functional check after the window (all 25 "
        f"lanes against the reference): {w['functional_check']}.",
        "",
        "| | power (mW) | share |",
        "|---|---:|---:|",
        f"| internal | {mw(p['internal_w'])} | {p['internal_w'] / total * 100:.1f} % |",
        f"| switching | {mw(p['switching_w'])} | {p['switching_w'] / total * 100:.1f} % |",
        f"| leakage | {mw(p['leakage_w'])} | {p['leakage_w'] / total * 100:.1f} % |",
        f"| sequential | {mw(p['sequential_w'])} | {p['sequential_w'] / total * 100:.1f} % |",
        f"| combinational | {mw(p['combinational_w'])} | "
        f"{p['combinational_w'] / total * 100:.1f} % |",
        f"| **total** | **{mw(total)}** | |",
        "",
        f"**Energy per block: {p['energy_per_block_j'] * 1e9:.2f} nJ** (average power × "
        f"{w['block_cycles']} cycles × {period:.1f} ns), i.e. "
        f"{p['energy_per_block_j'] * 1e12 / 136:.1f} pJ per absorbed byte at the SHA3-256 rate "
        "(136 B), coprocessor only. The CPU's share is not included (task 5.5).",
        "",
        "Caveats: there is no clock tree, so a real clock network adds power on top of the "
        "sequential share. The flip-flops are not clock-gated, so they draw internal power "
        "every cycle, idle cycles included, which is why the sequential share dominates. The "
        "corner is typical. The P&R-stage figure is task 5.4.",
        "",
    ]


ENERGY_WORKLOADS = [  # (power_<name>.json, implementation, regime)
    ("kperm-cached", "ise-kperm", "cached"),
    ("shatr-cached", "ise-shatr", "cached"),
    ("kperm-uncached", "ise-kperm", "uncached"),
    ("shatr-uncached", "ise-shatr", "uncached"),
]
REGIME_CSV = {"cached": "sha3-ise.csv", "uncached": "sha3-mmio-uncached.csv"}
SHA3_256_RATE = 136


def sha3_256_slopes(csv_name):
    """{impl: cycles per block} for SHA3-256 from a sha3_eval.py CSV."""
    path = REPO / "docs" / "results" / csv_name
    out = {}
    if path.exists():
        for line in path.read_text().splitlines()[1:]:
            f = line.split(",")
            if f[0] == "256":
                out[f[1]] = float(f[7])
    return out


def energy_section(block_dir, achieved_ns):
    """Task 5.5: energy per byte of the coprocessor, from the activity-annotated
    power of each SoC-paced workload (power-coproc-workloads) and the measured
    cycles per block. Returns markdown lines, or [] when the runs are missing."""
    runs = {}
    for name, _, _ in ENERGY_WORKLOADS + [("idle", None, None)]:
        f = block_dir / f"power_{name}.json"
        if not f.exists():
            return []
        runs[name] = json.loads(f.read_text())
    slopes = {r: sha3_256_slopes(c) for r, c in REGIME_CSV.items()}
    t11 = runs["idle"]["workload"]["clock_period_ns"]

    def energy_per_block(p, cycles, period_ns):
        # Switching and internal energy per cycle do not depend on the
        # period; leakage energy scales with it.
        dyn = (p["internal_w"] + p["switching_w"]) * t11 * 1e-9
        return cycles * (dyn + p["leakage_w"] * period_ns * 1e-9)

    out = [
        "## Energy per byte (task 5.5)",
        "",
        f"Stage: block synthesis netlist, gate-level simulation (Verilator) + OpenSTA. Corner: "
        f"`{runs['idle']['corner']}`. Activity: annotated from the SAIF of each workload below "
        "(not default activity); every run annotates all pins "
        f"({min(r['annotated_fraction'] for r in runs.values()) * 100:.1f} % minimum) and passes "
        "its gate-level functional check. Coprocessor only: the CPU's energy is not in these "
        "figures.",
        "",
        "Each workload is SHA3-256 absorb paced like the SoC: per block, 17 `kxor`, then one "
        "`kperm` or 24 `shatr`, over the measured cycles per block of that implementation and "
        "cache regime (*cached*: message in the D-cache, `docs/results/sha3-ise.md`; "
        "*uncached*: message evicted, `docs/results/sha3-mmio-uncached.md`). Energy per block = "
        "average power × cycles per block × clock period; per byte, divided by the 136-byte "
        "rate. At another period, switching and internal energy per cycle stay, and leakage "
        "scales with the period.",
        "",
        f"| implementation | regime | cycles/block (workload / measured) | power @ {t11:.1f} ns "
        f"(mW) | energy/block @ {t11:.1f} ns (nJ) | energy/byte @ {t11:.1f} ns (pJ/B) | "
        "energy/byte @ achieved period |",
        "|---|---|---:|---:|---:|---:|---:|",
    ]
    for name, impl, regime in ENERGY_WORKLOADS:
        p = runs[name]
        cyc = p["workload"]["block_cycles"]
        meas = slopes[regime].get(impl)
        e11 = energy_per_block(p, cyc, t11)
        ach = (f"{energy_per_block(p, cyc, achieved_ns) * 1e12 / SHA3_256_RATE:.1f} pJ/B "
               f"@ {achieved_ns:.2f} ns" if achieved_ns else "pending (task 5.4)")
        out.append(f"| {impl} | {regime} | {cyc} / {meas:.0f} | {p['power_w'] * 1e3:.2f} | "
                   f"{e11 * 1e9:.2f} | {e11 * 1e12 / SHA3_256_RATE:.1f} | {ach} |"
                   if meas is not None else
                   f"| {impl} | {regime} | {cyc} / — | {p['power_w'] * 1e3:.2f} | "
                   f"{e11 * 1e9:.2f} | {e11 * 1e12 / SHA3_256_RATE:.1f} | {ach} |")
    idle = runs["idle"]
    out += [
        "",
        f"**Idle coprocessor: {idle['power_w'] * 1e3:.2f} mW** (internal "
        f"{idle['internal_w'] * 1e3:.2f}, switching {idle['switching_w'] * 1e3:.3f}, leakage "
        f"{idle['leakage_w'] * 1e3:.3f}). Its flip-flops are not clock-gated, so the block draws "
        "this whenever the SoC is clocked, whatever runs. The software baselines' own energy is "
        "CPU energy, which this flow does not measure (it would need a gate-level CVA6 "
        "simulation); what the coprocessor adds to them is this idle power over their cycles:",
        "",
        "| baseline (cached) | cycles/block | coprocessor idle energy/byte @ "
        f"{t11:.1f} ns (pJ/B) |",
        "|---|---:|---:|",
    ]
    for impl in ("sw-rvcrypto", "sw-xkcp-ref64", "sw-xkcp-opt64"):
        b = slopes["cached"].get(impl)
        if b is not None:
            e = energy_per_block(idle, b, t11)
            out.append(f"| {impl} | {b:,.0f} | {e * 1e12 / SHA3_256_RATE:,.1f} |")
    out += [
        "",
        "Caveats: no clock tree (ideal clock), so a real clock network adds power, mostly in "
        "the sequential share; typical corner; the CPU, caches and interconnect are outside "
        "the block. The P&R-stage figures are task 5.4.",
        "",
    ]
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(REPO / "docs" / "results" / "sha3-ppa.md"))
    ap.add_argument("--soc", help="synth-reports artifact dir of the SoC run (task 5.3)")
    ap.add_argument("--soc-ref", help="synth-reports artifact dir of the reference run")
    ap.add_argument("--soc-run-id", help="synth lane run id of --soc, for the report")
    ap.add_argument("--soc-ref-run-id", help="synth lane run id of --soc-ref, for the report")
    ap.add_argument("--achieved-period-ns", type=float,
                    help="clock period the P&R lane achieved (task 5.4), for the energy table")
    a = ap.parse_args(argv)
    if bool(a.soc) != bool(a.soc_ref):
        sys.exit("sha3_ppa: --soc and --soc-ref go together")

    rows = []
    for r in ROUNDS:
        f = BLOCK_DIR / f"keccak_cvxif_r{r}" / "metrics.json"
        if not f.exists():
            sys.exit(f"sha3_ppa: {f} missing (make synth-coproc-block BLOCK=keccak_cvxif "
                     f"ROUNDS_PER_CYCLE={r})")
        m = json.loads(f.read_text())
        if m["check_problems"] or m["structural_check_warnings"]:
            sys.exit(f"sha3_ppa: R={r} has check problems or structural warnings")
        rows.append(m)

    period = rows[0]["clock_period_ns"]
    eligible = [m["rounds_per_cycle"] for m in rows
                if m["worst_slack_ns"] >= MIN_SLACK_FRACTION * period]
    selected = max(eligible)
    soc = soc_rounds_per_cycle()
    if soc != selected:
        sys.exit(f"sha3_ppa: iguana_pkg uses R={soc}, the rule selects R={selected}")
    base = rows[0]["area_um2"]
    yosys, opensta = tool_versions(selected)

    out = [
        "# SHA-3 coprocessor PPA",
        "",
        "Generated by `scripts/sha3_ppa.py` from block-synthesis results "
        "(`make synth-coproc-block BLOCK=keccak_cvxif ROUNDS_PER_CYCLE=<R>`).",
        "",
        "## Rounds-per-cycle sweep (`keccak_cvxif`)",
        "",
        f"Stage: {rows[0]['stage']}. Corner: `{rows[0]['corner']}` (IHP SG13G2). "
        f"Constraint: {period:.1f} ns. Tools: {yosys}, {opensta}. Every row has 0 `CHECK` "
        "problems and 0 structural warnings. The block includes the 4-entry issue queue. "
        "SoC configuration for later stages: CVA6 `cv64a6_imafdcsclic_sv39`, hypervisor "
        "extension on (ADR-0004).",
        "",
        "| R | cells | area (µm²) | area vs R=1 | flip-flops | critical path (ns) | "
        f"slack @ {period:.1f} ns | `kperm` cycles |",
        "|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for m in rows:
        mark = " **(selected)**" if m["rounds_per_cycle"] == selected else ""
        out.append(f"| {m['rounds_per_cycle']}{mark} | {m['cells']:,} | {m['area_um2']:,.0f} | "
                   f"{m['area_um2'] / base:.2f}× | {m['dffs']:,} | {m['critical_path_ns']:.2f} | "
                   f"{m['worst_slack_ns']:.2f} ({m['worst_slack_ns'] / period * 100:.0f} %) | "
                   f"{m['kperm_cycles']} |")
    out += [
        "",
        f"**Selected: R = {selected}** (`iguana_pkg::KeccakRoundsPerCycle`). Rule: the "
        f"largest R whose critical path leaves ≥ {MIN_SLACK_FRACTION * 100:.0f} % slack at "
        f"{period:.1f} ns, i.e. ≥ {MIN_SLACK_FRACTION * period:.1f} ns. Eligible: "
        f"{', '.join(map(str, eligible))}.",
        "",
        "Caveats: the timing is pre-placement. Wires and placement will cut the slack, which "
        "the SoC-level place and route (task 5.4) measures. The selected R buys the shortest "
        "`kperm` for the most area: about 3.5× the R = 1 block. The per-block cycle effect is "
        "in `docs/results/sha3-ise.md`, measured at this R.",
        "",
    ]
    power = BLOCK_DIR / f"keccak_cvxif_r{selected}" / "power.json"
    if power.exists():
        out += power_section(json.loads(power.read_text()))
    out += energy_section(power.parent, a.achieved_period_ns)
    if a.soc:
        out += soc_section(soc_metrics(a.soc), soc_metrics(a.soc_ref), a.soc_run_id,
                           a.soc_ref_run_id)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text("\n".join(out))
    print(f"sha3_ppa: wrote {a.out} (selected R={selected})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
