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

With --soc-both DIR (task 8.2) it adds the SoC synthesis with both SHA-3
blocks: totals against the reference and the coprocessor-only run, each
block's kept-hierarchy instance, and the per-instance synthesis spread.

With --pnr RUN_DIR --pnr-ref REF_DIR (task 5.4) it adds the SoC P&R
section from two P&R lane runs' `pnr-reports` artifacts (`gh run download
<id> -n pnr-reports -D <dir>`): stages reached, WNS/TNS per stage, grt
congestion and placement figures, against the pre-coprocessor reference.
`grt` figures are labelled as taken before post-route repair.

With --pnr-repair DIR --pnr-ref-repair DIR (change
bounded-grt-repair-measurement), each the `pnr-reports` artifact of a run
that resumed one side's `grt` checkpoint with skip_grt_repair=0, it adds
WNS/TNS and design area after `grt_repair` and takes the achieved period
from there, but only when both sides' repair completed. Otherwise it names
each attempt's outcome and keeps the `grt` figures.

Usage: scripts/sha3_ppa.py [--out docs/results/sha3-ppa.md]
                           [--soc RUN_DIR --soc-ref REF_DIR]
                           [--soc-run-id N --soc-ref-run-id N]
                           [--soc-both RUN_DIR --soc-both-run-id N]
                           [--pnr RUN_DIR --pnr-ref REF_DIR]
                           [--pnr-run-id N --pnr-ref-run-id N]
                           [--pnr-repair DIR --pnr-ref-repair DIR]
                           [--pnr-repair-run-id N --pnr-ref-repair-run-id N]
                           [--achieved-period-ns T --achieved-period-source TEXT]
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


def energy_per_block(p, cycles, period_ns):
    """Energy of `cycles` cycles at period_ns from a power_<workload>.json run.
    Switching and internal energy per cycle do not depend on the period;
    leakage energy scales with it."""
    t_sim = p["workload"]["clock_period_ns"]
    dyn = (p["internal_w"] + p["switching_w"]) * t_sim * 1e-9
    return cycles * (dyn + p["leakage_w"] * period_ns * 1e-9)


def energy_section(block_dir, achieved_ns, achieved_src=""):
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
        "scales with the period." + (f" Achieved period: {achieved_ns:.2f} ns ({achieved_src})."
                                     if achieved_ns else ""),
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


def instance_metrics(d, module):
    """(cells, area, flip-flops) of a kept-hierarchy module in a synth lane
    run's area report, or None."""
    text = (reports_dir(d) / "basilisk_area.rpt").read_text()
    m = re.search(r"=== (" + module + r"\S*) ===(.*?)Chip area for module '\\\1': ([\d.]+)",
                  text, re.S)
    if not m:
        return None
    kc = re.search(r"^\s+(\d+)\s+\S+\s+cells$", m.group(2), re.M)
    kd = sum(int(n) for n, _ in re.findall(r"^\s+(\d+)\s+\S+\s+(sg13g2_\w*df\w*)$",
                                            m.group(2), re.M))
    return int(kc.group(1)) if kc else None, float(m.group(3)), kd


def soc_both_section(run, ref, single, d_run, d_single, ids):
    """Task 8.2: SoC synthesis with both SHA-3 blocks, against the
    pre-coprocessor reference and the coprocessor-only run (task 5.3)."""
    run_id, ref_id, single_id = ids
    out = [
        "## SoC synthesis with both arms (task 8.2)",
        "",
        f"Synth lane run {run_id or '?'} (SoC with `keccak_cvxif` and `keccak_mmio`, "
        f"R = {soc_rounds_per_cycle()}) against run {ref_id or '?'} (before the coprocessor) and "
        f"run {single_id or '?'} (coprocessor only, task 5.3). Same flow: Yosys synthesis, "
        f"`typ_1p20V_25C`. Yosys `CHECK` problems: {run['check']}.",
        "",
        "| | reference | coprocessor only | both arms | delta vs reference |",
        "|---|---:|---:|---:|---:|",
        f"| cells | {ref['cells']:,} | {single['cells']:,} | {run['cells']:,} | "
        f"{pct(run['cells'], ref['cells'])} |",
        f"| area (µm²) | {ref['area']:,.0f} | {single['area']:,.0f} | {run['area']:,.0f} | "
        f"{pct(run['area'], ref['area'])} |",
        f"| flip-flops | {ref['dffs']:,} | {single['dffs']:,} | {run['dffs']:,} | "
        f"{pct(run['dffs'], ref['dffs'])} |",
        "",
        "Each block is its own instance (kept hierarchy):",
        "",
        "| instance | cells | area (µm²) | flip-flops | share of SoC area |",
        "|---|---:|---:|---:|---:|",
    ]
    insts = {}
    for name in ("keccak_cvxif", "keccak_mmio"):
        v = instance_metrics(d_run, name)
        insts[name] = v
        if v:
            out.append(f"| `i_{name}` | {v[0]:,} | {v[1]:,.0f} | {v[2]:,} | "
                       f"{v[1] / run['area'] * 100:.2f} % |")
    single_cvxif = instance_metrics(d_single, "keccak_cvxif")
    block = BLOCK_DIR / f"keccak_cvxif_r{soc_rounds_per_cycle()}" / "metrics.json"
    block_area = json.loads(block.read_text())["area_um2"] if block.exists() else None
    if insts["keccak_cvxif"] and single_cvxif:
        out += [
            "",
            f"Synthesis spread: the same `keccak_cvxif` RTL comes out at "
            f"{single_cvxif[1]:,.0f} µm² in run {single_id or '?'}, "
            f"{insts['keccak_cvxif'][1]:,.0f} µm² here"
            + (f", and {block_area:,.0f} µm² as a standalone block" if block_area else "")
            + ". Neither the block's RTL nor its parameters changed between the runs, yet its "
            "synthesized area differs by up to 11 % between them, far outside the ±0.04 % "
            "run-to-run noise the SoC flow shows on untouched modules. The cause is not "
            "investigated. Per-instance SoC areas carry that uncertainty; the R sweep's "
            "block-level areas come from one consistent flow.",
        ]
    cva6 = (ref["modules"].get("cva6", 0), run["modules"].get("cva6", 0))
    out += [
        "",
        f"`cva6`: {cva6[0]:,.0f} → {cva6[1]:,.0f} µm² ({cva6[1] - cva6[0]:+,.0f}), as in task "
        "5.3 with CV-X-IF on; not investigated.",
        "",
    ]
    return out


PNR_STAGES = ["dpl", "cts", "grt"]


def pnr_metrics(d):
    """Stage outcomes, WNS/TNS per stage, grt congestion and placement figures
    from a P&R lane run's `pnr-reports` artifact (gh run download <id> -n
    pnr-reports -D <dir>)."""
    d = Path(d)
    rep = d / "reports"
    status = {}
    for line in (d / "save" / "pnr_status.log").read_text().splitlines():
        f = line.split()
        if len(f) >= 2 and status.get(f[0]) != "ok":  # keep "ok" over a later stop-after
            status[f[0]] = f[1]
    timing = {}
    for s in PNR_STAGES:
        f = rep / f"basilisk.{s}.rpt"
        if f.exists():
            t = f.read_text(errors="replace")
            wns = re.search(r"^wns max (\S+)", t, re.M)
            tns = re.search(r"^tns max (\S+)", t, re.M)
            if wns and tns:
                timing[s] = (float(wns.group(1)), float(tns.group(1)))
    grt = (rep / "pnr_grt.log").read_text(errors="replace")
    dpl = (rep / "pnr_dpl.log").read_text(errors="replace")
    cts = (rep / "pnr_cts.log").read_text(errors="replace")
    total = re.findall(r"^Total\s+\d+\s+\d+\s+([\d.]+)%", grt, re.M)
    metal3 = re.findall(r"^Metal3\s+\d+\s+\d+\s+([\d.]+)%", grt, re.M)
    wl = re.findall(r"GRT-0018\] Total wirelength: (\d+)", grt)
    util = re.search(r"DPL-0009\] Utilization: ([\d.]+)%", dpl)
    hpwl_dpl = re.search(r"DPL-0022\] HPWL after\s+([\d.]+)", dpl)
    hpwl_cts = re.findall(r"legalized HPWL\s+([\d.]+)", cts)
    return {
        "status": status, "timing": timing,
        "grt_demand_pct": float(total[-1]) if total else None,
        "grt_metal3_pct": float(metal3[-1]) if metal3 else None,
        "grt_wirelength_um": int(wl[-1]) if wl else None,
        "dpl_util_pct": float(util.group(1)) if util else None,
        "hpwl_dpl_um": float(hpwl_dpl.group(1)) if hpwl_dpl else None,
        "hpwl_cts_um": float(hpwl_cts[-1]) if hpwl_cts else None,
        "grt_area_um2": pnr_design_area(rep / "pnr_grt.log", "grt"),
    }


def pnr_design_area(log, when):
    """Design area (um^2) that report_metrics printed for checkpoint `when`
    into a stage log, or None."""
    if not log.exists():
        return None
    m = re.search(rf"^basilisk\.{when} report_design_area\n-+\nDesign area (\d+) um\^2",
                  log.read_text(errors="replace"), re.M)
    return int(m.group(1)) if m else None


def pnr_repair_metrics(d):
    """grt_repair outcome, WNS/TNS and design area after it, from the
    `pnr-reports` artifact of a P&R run that resumed from a `grt` checkpoint
    with skip_grt_repair=0 (change bounded-grt-repair-measurement). Outcome is
    "completed", "skipped" (the repair did not run), "timed out", "failed" or
    "not run"; timing and area are None unless it completed."""
    d = Path(d)
    rep = d / "reports"
    lines = [line.split(maxsplit=2) for line in
             (d / "save" / "pnr_status.log").read_text().splitlines()]
    lines = [f + [""] * (3 - len(f)) for f in lines if f and f[0] == "grt_repair"]
    if any(f[1] == "ok" and "skipped" in f[2] for f in lines):
        outcome = "skipped"
    elif any(f[1] == "ok" for f in lines):
        outcome = "completed"
    elif any(f[1] == "failed" and "exit=124" in f[2] for f in lines):
        outcome = "timed out"
    elif any(f[1] == "failed" for f in lines):
        outcome = "failed"
    else:
        outcome = "not run"
    timing = area = None
    f = rep / "basilisk.grt_repaired.rpt"
    if outcome == "completed" and f.exists():
        t = f.read_text(errors="replace")
        wns = re.search(r"^wns max (\S+)", t, re.M)
        tns = re.search(r"^tns max (\S+)", t, re.M)
        if wns and tns:
            timing = (float(wns.group(1)), float(tns.group(1)))
        area = pnr_design_area(rep / "pnr_grt_repair.log", "grt_repaired")
    if outcome == "completed" and timing is None:
        outcome = "failed"  # no report to quote: treat as not completed (design D6)
    return {"outcome": outcome, "timing": timing, "area_um2": area}


def pnr_repair_done(repair, ref_repair):
    """True when both sides' post-route repair completed, the only case in
    which figures after it are quoted (sha3-evaluation spec: both sides of a
    comparison share one repair status)."""
    return bool(repair and ref_repair and repair["outcome"] == ref_repair["outcome"] == "completed")


PNR_GATED =["floorplan", "pre_place", "gpl", "dpl", "cts", "grt"]


def pnr_latest(m):
    """The latest gated stage a P&R run reached (status ok)."""
    reached = [s for s in PNR_GATED if m["status"].get(s) == "ok"]
    return reached[-1] if reached else None


def pnr_achieved_period(m, period, repair=None):
    """(period, stage, wns, repaired) achieved by a P&R run: the constraint
    minus the WNS after post-route repair when `repair` is given and
    completed, else after its latest gated stage; None when that stage has no
    timing report."""
    if repair and repair["outcome"] == "completed":
        wns = repair["timing"][0]
        return period - wns, "grt_repair", wns, True
    latest = pnr_latest(m)
    if latest not in m["timing"]:
        return None
    wns = m["timing"][latest][0]
    return period - wns, latest, wns, False


def pnr_stage_label(stage, repaired):
    """How a stage is named next to a figure: a `grt` figure says that
    post-route repair did not run before it."""
    if repaired:
        return f"`{stage}`"
    if stage == "grt":
        return "`grt`, before post-route repair"
    return f"`{stage}`"


def pnr_repair_text(repair, ref_repair, repair_ids):
    """Sentence naming each side's post-route repair attempt and outcome, for
    a report that quotes figures from before the repair."""
    ids = repair_ids or (None, None)
    parts = [f"{name}: run {rid or '?'}, {r['outcome']}"
             for name, r, rid in (("reference", ref_repair, ids[1]),
                                  ("with both arms", repair, ids[0])) if r]
    return ("Post-route repair was attempted (" + "; ".join(parts) + ") and did not complete on "
            "both sides, so every timing figure here is from before it.")


def pnr_stage_text(latest, repaired, repair, ref_repair, repair_ids):
    """The "Stage used" sentence of the P&R section, naming the repair status."""
    if repaired:
        stage = (f"**Stage used: grt_repair**, post-route timing repair resumed from each run's "
                 f"`grt` checkpoint (reference: run {(repair_ids or (None, None))[1] or '?'}; "
                 f"with both arms: run {(repair_ids or (None, None))[0] or '?'}; "
                 "`grt_repair.tcl`'s bounded repair, `-repair_tns 20 -max_buffer_percent 15`). "
                 "Detailed routing is best-effort and was not run.")
    elif latest == "grt":
        stage = ("**Stage used: grt, before post-route repair**: the lane's gate. `grt_repair` "
                 "is skipped by default, and detailed routing is best-effort and was not run.")
    else:
        stage = (f"**Stage used: {latest or 'none'}**, the latest stage the run reached "
                 "(detailed routing is best-effort and was not run).")
    if (repair or ref_repair) and not repaired:
        stage += " " + pnr_repair_text(repair, ref_repair, repair_ids)
    return stage


def pnr_section(run, ref, run_id, ref_id, period, repair=None, ref_repair=None,
                repair_ids=None):
    """Task 5.4: SoC P&R with the SHA-3 arms against the pre-coprocessor
    reference, at the latest stage the run reached. With both sides'
    post-route repair runs (change bounded-grt-repair-measurement), figures
    after the repair are added when both completed."""
    latest = pnr_latest(run)
    repaired = pnr_repair_done(repair, ref_repair)

    def num(x, fmt):
        return format(x, fmt) if x is not None else "—"

    stage = pnr_stage_text(latest, repaired, repair, ref_repair, repair_ids)
    out = [
        "## SoC place and route (task 5.4)",
        "",
        f"P&R lane run {run_id or '?'} (the SoC with both SHA-3 arms, `keccak_cvxif` and "
        f"`keccak_mmio`, R = {soc_rounds_per_cycle()}) against run {ref_id or '?'} (the "
        "pre-coprocessor tree, the clean reference; `docs/infra-plan.md` Phase 11). Same flow and "
        "settings: taped-out die, `gpl` pass 2 timing-driven repair virtual, `stop_after=grt`. "
        f"{stage} Corner: `tt` (`typ_1p20V_25C`). Constraint: {period:.1f} ns.",
        "",
        "| | reference | with both arms |",
        "|---|---:|---:|",
    ]
    for s in PNR_STAGES:
        if s in run["timing"] and s in ref["timing"]:
            (rw, rt), (fw, ft) = run["timing"][s], ref["timing"][s]
            label = "`grt`, before post-route repair" if s == "grt" else f"`{s}`"
            out.append(f"| WNS / TNS after {label} (ns) | {fw:.2f} / {ft:,.0f} | "
                       f"{rw:.2f} / {rt:,.0f} |")
    if repaired:
        (rw, rt), (fw, ft) = repair["timing"], ref_repair["timing"]
        out.append(f"| WNS / TNS after `grt_repair` (ns) | {fw:.2f} / {ft:,.0f} | "
                   f"{rw:.2f} / {rt:,.0f} |")
        out.append(f"| design area after `grt` / after `grt_repair` (µm²) | "
                   f"{num(ref['grt_area_um2'], ',')} / {num(ref_repair['area_um2'], ',')} | "
                   f"{num(run['grt_area_um2'], ',')} / {num(repair['area_um2'], ',')} |")
    out += [
        f"| `grt` total demand | {num(ref['grt_demand_pct'], '.2f')} % | "
        f"{num(run['grt_demand_pct'], '.2f')} % |",
        f"| `grt` Metal3 demand | {num(ref['grt_metal3_pct'], '.2f')} % | "
        f"{num(run['grt_metal3_pct'], '.2f')} % |",
        f"| `grt` wirelength (µm) | {num(ref['grt_wirelength_um'], ',')} | "
        f"{num(run['grt_wirelength_um'], ',')} |",
        f"| utilization entering `dpl` (`DPL-0009`) | {num(ref['dpl_util_pct'], '.1f')} % | "
        f"{num(run['dpl_util_pct'], '.1f')} % |",
        f"| HPWL after `dpl` / after `cts` (M µm) | "
        f"{num(ref['hpwl_dpl_um'] and ref['hpwl_dpl_um'] / 1e6, '.1f')} / "
        f"{num(ref['hpwl_cts_um'] and ref['hpwl_cts_um'] / 1e6, '.1f')} | "
        f"{num(run['hpwl_dpl_um'] and run['hpwl_dpl_um'] / 1e6, '.1f')} / "
        f"{num(run['hpwl_cts_um'] and run['hpwl_cts_um'] / 1e6, '.1f')} |",
        "",
    ]
    ach = pnr_achieved_period(run, period, repair if repaired else None)
    if ach:
        caveat = ("" if ach[3] else " It is a figure from before post-route repair, not the "
                  "SoC's maximum frequency: post-route repair may close part of the gap from "
                  "`cts` to `grt`.")
        out += [f"Achieved period: {ach[0]:.2f} ns ({period:.1f} ns minus WNS {ach[2]:.2f} ns "
                f"after {pnr_stage_label(ach[1], ach[3])}), used by the energy section."
                f"{caveat} The critical path is outside the SHA-3 blocks: WNS barely moves "
                "against the reference.", ""]
    out += [
        "**SoC power: not reported.** The lane's `report_power` uses default activity (no "
        "workload SAIF), which the evaluation spec rejects as workload power. In this netlist it "
        "is also broken: from `pre_place` on, the combinational share collapses against the "
        "reference (0.006 vs 0.237 W), because OpenSTA's default activity stops propagating "
        "(`docs/infra-plan.md` Phase 17, not investigated). The SHA-3 blocks' power is the "
        "activity-annotated block power in the sections above.",
        "",
        "Caveats: one run each, and placement varies from run to run: congestion fell although "
        "the netlist grew. Area, power and energy of the SHA-3 blocks themselves come from "
        "synthesis (per instance) and from block-level gate-level power, not from this delta.",
        "",
    ]
    return out


MMIO_WORKLOADS = [  # (power_<name>.json, implementation, regime)
    ("cpu-cached", "mmio-cpu", "cached"),
    ("dma-cached", "mmio-dma", "cached"),
    ("cpu-uncached", "mmio-cpu", "uncached"),
    ("dma-uncached", "mmio-dma", "uncached"),
]


def mmio_section(r, cvxif, achieved_ns=None):
    """Task 8.1: block synthesis and activity-annotated power of keccak_mmio
    at the SoC's R, next to keccak_cvxif's figures. [] when not run yet."""
    d = BLOCK_DIR / f"keccak_mmio_r{r}"
    if not (d / "metrics.json").exists():
        return []
    m = json.loads((d / "metrics.json").read_text())
    period = m["clock_period_ns"]
    out = [
        "## MMIO accelerator block (`keccak_mmio`, task 8.1)",
        "",
        f"Stage: {m['stage']}. Corner: `{m['corner']}`. Constraint: {period:.1f} ns. R = {r}, "
        "the SoC's value, so it shares the coprocessor's round datapath; the AXI front end is "
        "`axi_to_detailed_mem` with a 5-bit ID, as on Cheshire's external port. "
        f"`CHECK` problems: {m['check_problems']}; structural warnings: "
        f"{m['structural_check_warnings']}.",
        "",
        "| block | cells | area (µm²) | flip-flops | critical path (ns) | "
        f"slack @ {period:.1f} ns | permutation cycles |",
        "|---|---:|---:|---:|---:|---:|---:|",
        f"| `keccak_mmio` | {m['cells']:,} | {m['area_um2']:,.0f} | {m['dffs']:,} | "
        f"{m['critical_path_ns']:.2f} | {m['worst_slack_ns']:.2f} | {m.get('perm_cycles', '—')} |",
    ]
    if cvxif:
        out.append(f"| `keccak_cvxif` | {cvxif['cells']:,} | {cvxif['area_um2']:,.0f} | "
                   f"{cvxif['dffs']:,} | {cvxif['critical_path_ns']:.2f} | "
                   f"{cvxif['worst_slack_ns']:.2f} | {cvxif['kperm_cycles']} (`kperm`) |")
    out.append("")
    runs = {}
    for name, _, _ in MMIO_WORKLOADS + [("mmio-idle", None, None)]:
        f = d / f"power_{name}.json"
        if not f.exists():
            return out + ["Power: not run yet (`make power-coproc-workloads BLOCK=keccak_mmio "
                          f"ROUNDS_PER_CYCLE={r}`).", ""]
        runs[name] = json.loads(f.read_text())
    slopes = {reg: sha3_256_slopes(c) for reg, c in REGIME_CSV.items()}
    idle = runs["mmio-idle"]
    t11 = idle["workload"]["clock_period_ns"]
    out += [
        "Power: block synthesis netlist, gate-level simulation (Verilator) + OpenSTA, "
        f"`{idle['corner']}`, {t11:.1f} ns ideal clock. Activity: annotated from the SAIF of each "
        "workload (not default activity); every run annotates all pins "
        f"({min(x['annotated_fraction'] for x in runs.values()) * 100:.1f} % minimum) and passes "
        "its gate-level functional check. Workloads drive the AXI port as the SoC does, per "
        "block: *mmio-cpu*, 17 single-beat lane stores, START, STATUS polls; *mmio-dma*, one "
        "17-beat burst, START, polls; each over the measured cycles per block. Accelerator "
        "only: the CPU, the iDMA and the interconnect are not in these figures.",
        "",
        f"| implementation | regime | cycles/block (workload / measured) | power @ {t11:.1f} ns "
        f"(mW) | energy/block @ {t11:.1f} ns (nJ) | energy/byte @ {t11:.1f} ns (pJ/B) | "
        "energy/byte @ achieved period |",
        "|---|---|---:|---:|---:|---:|---:|",
    ]
    for name, impl, regime in MMIO_WORKLOADS:
        p = runs[name]
        cyc = p["workload"]["block_cycles"]
        meas = slopes[regime].get(impl)
        e = energy_per_block(p, cyc, t11)
        ach = (f"{energy_per_block(p, cyc, achieved_ns) * 1e12 / SHA3_256_RATE:.1f} pJ/B "
               f"@ {achieved_ns:.2f} ns" if achieved_ns else "pending (task 5.4)")
        out.append(f"| {impl} | {regime} | {cyc} / {f'{meas:.0f}' if meas else '—'} | "
                   f"{p['power_w'] * 1e3:.2f} | {e * 1e9:.2f} | "
                   f"{e * 1e12 / SHA3_256_RATE:.1f} | {ach} |")
    out += [
        "",
        f"**Idle accelerator: {idle['power_w'] * 1e3:.2f} mW** (internal "
        f"{idle['internal_w'] * 1e3:.2f}, switching {idle['switching_w'] * 1e3:.3f}, leakage "
        f"{idle['leakage_w'] * 1e3:.3f}); like the coprocessor, its state flip-flops are not "
        "clock-gated.",
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
    ap.add_argument("--soc-both", help="synth-reports artifact dir of the SoC run with both "
                    "SHA-3 blocks (task 8.2); needs --soc and --soc-ref")
    ap.add_argument("--soc-both-run-id", help="synth lane run id of --soc-both, for the report")
    ap.add_argument("--pnr", help="pnr-reports artifact dir of the SoC P&R run (task 5.4)")
    ap.add_argument("--pnr-ref", help="pnr-reports artifact dir of the reference P&R run")
    ap.add_argument("--pnr-run-id", help="P&R lane run id of --pnr, for the report")
    ap.add_argument("--pnr-ref-run-id", help="P&R lane run id of --pnr-ref, for the report")
    ap.add_argument("--pnr-repair", help="pnr-reports artifact dir of the post-route repair "
                    "run that resumed --pnr's grt checkpoint (change "
                    "bounded-grt-repair-measurement); needs --pnr-ref-repair")
    ap.add_argument("--pnr-ref-repair", help="pnr-reports artifact dir of the post-route repair "
                    "run that resumed --pnr-ref's grt checkpoint; needs --pnr-repair")
    ap.add_argument("--pnr-repair-run-id", help="P&R lane run id of --pnr-repair, for the report")
    ap.add_argument("--pnr-ref-repair-run-id", help="P&R lane run id of --pnr-ref-repair, for "
                    "the report")
    ap.add_argument("--achieved-period-source", default="",
                    help="where --achieved-period-ns comes from (run, stage, corner), for the report")
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
    if bool(a.pnr) != bool(a.pnr_ref):
        sys.exit("sha3_ppa: --pnr and --pnr-ref go together")
    if bool(a.pnr_repair) != bool(a.pnr_ref_repair):
        sys.exit("sha3_ppa: --pnr-repair and --pnr-ref-repair go together")
    if a.pnr_repair and not a.pnr:
        sys.exit("sha3_ppa: --pnr-repair and --pnr-ref-repair need --pnr and --pnr-ref")
    pnr_run = pnr_metrics(a.pnr) if a.pnr else None
    repair = pnr_repair_metrics(a.pnr_repair) if a.pnr_repair else None
    ref_repair = pnr_repair_metrics(a.pnr_ref_repair) if a.pnr_ref_repair else None
    repaired = pnr_repair_done(repair, ref_repair)
    achieved, achieved_src = a.achieved_period_ns, a.achieved_period_source
    if achieved is None and pnr_run:
        ach = pnr_achieved_period(pnr_run, period, repair if repaired else None)
        if ach:
            achieved = ach[0]
            src_run = a.pnr_repair_run_id if ach[3] else a.pnr_run_id
            achieved_src = (f"{period:.1f} ns constraint minus WNS {ach[2]:.2f} ns after "
                            f"{pnr_stage_label(ach[1], ach[3])}, tt, SoC P&R run "
                            f"{src_run or '?'}; see the P&R section")
    out += energy_section(power.parent, achieved, achieved_src)
    out += mmio_section(selected, next(m for m in rows if m["rounds_per_cycle"] == selected),
                        achieved)
    if pnr_run:
        out += pnr_section(pnr_run, pnr_metrics(a.pnr_ref), a.pnr_run_id, a.pnr_ref_run_id,
                           period, repair, ref_repair,
                           (a.pnr_repair_run_id, a.pnr_ref_repair_run_id))
    if a.soc:
        out += soc_section(soc_metrics(a.soc), soc_metrics(a.soc_ref), a.soc_run_id,
                           a.soc_ref_run_id)
    if a.soc_both:
        if not a.soc:
            sys.exit("sha3_ppa: --soc-both needs --soc (coprocessor only) and --soc-ref")
        out += soc_both_section(soc_metrics(a.soc_both), soc_metrics(a.soc_ref),
                                soc_metrics(a.soc), a.soc_both, a.soc,
                                (a.soc_both_run_id, a.soc_ref_run_id, a.soc_run_id))
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text("\n".join(out))
    print(f"sha3_ppa: wrote {a.out} (selected R={selected})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
