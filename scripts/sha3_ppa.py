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
congestion and placement figures, and grt power under the lane's uniform
activity, against the reference (the same SoC without the SHA-3 hardware).
`grt` figures are labelled as taken before post-route repair. The script
refuses the comparison, naming the run and the item, unless both runs passed
the gated legality check after `dpl` and `cts` and report the same die
(change requote-sha3-pnr-legal-placement), so runs from before change
use-diamond-legalizer can no longer be compared. It also refuses two runs
whose logged flow settings differ (gpl density, grt Metal2 and SRAM Metal5
hold-backs, stop_after, and drt's budget and antenna mode when both routed),
states those settings in the section, and gives each run's routed outcome:
the router's final count and iterations and the antenna checker's counts, or
that the run has no routed design (change
adopt-drc-clean-defaults-and-requote, design D5).

With --pnr-repair DIR --pnr-ref-repair DIR (change
bounded-grt-repair-measurement), each the `pnr-reports` artifact of a run
that resumed one side's `grt` checkpoint with skip_grt_repair=0, it adds
WNS/TNS and design area after `grt_repair` and takes the achieved period
from there, but only when both sides' repair completed. Otherwise it names
each attempt's outcome and keeps the `grt` figures. Either may be given
alone: the second side is not attempted once the first did not complete
(design D4).

Usage: scripts/sha3_ppa.py [--out docs/results/sha3-ppa.md]
                           [--soc RUN_DIR --soc-ref REF_DIR]
                           [--soc-run-id N --soc-ref-run-id N]
                           [--soc-both RUN_DIR --soc-both-run-id N]
                           [--pnr RUN_DIR --pnr-ref REF_DIR]
                           [--pnr-run-id N --pnr-ref-run-id N]
                           [--pnr-repair DIR] [--pnr-ref-repair DIR]
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
        **pnr_placement_facts(rep, dpl, cts),
        "grt_power_w": pnr_uniform_power(rep / "basilisk.grt.rpt"),
        "clock_buffers": pnr_clock_buffers(cts),
        "grt_worst_path": pnr_worst_path(rep / "basilisk.grt.rpt"),
        "status": status, "timing": timing,
        "grt_demand_pct": float(total[-1]) if total else None,
        "grt_metal3_pct": float(metal3[-1]) if metal3 else None,
        "grt_wirelength_um": int(wl[-1]) if wl else None,
        "dpl_util_pct": float(util.group(1)) if util else None,
        "hpwl_dpl_um": float(hpwl_dpl.group(1)) if hpwl_dpl else None,
        "hpwl_cts_um": float(hpwl_cts[-1]) if hpwl_cts else None,
        "grt_area_um2": pnr_design_area(rep / "pnr_grt.log", "grt"),
        "cts_overlaps": pnr_cts_overlaps(cts, rep / "basilisk_cts_check_placement.rpt"),
        **pnr_flow_settings(d),
    }


def pnr_status_rows(d):
    """pnr_status.log as (stage, status, detail) rows, in order."""
    rows = []
    for line in (Path(d) / "save" / "pnr_status.log").read_text().splitlines():
        f = line.split(maxsplit=2)
        if len(f) >= 2:
            rows.append((f[0], f[1], f[2] if len(f) > 2 else ""))
    return rows


# The settings two runs must share (sha3-evaluation spec: the same flow
# inputs), in the order the flow sentence names them.
PNR_SETTINGS = ["gpl density", "grt Metal2 hold-back", "SRAM Metal5 hold-back",
                "stop after", "drt iteration budget", "antenna repair"]


def pnr_flow_settings(d):
    """The flow settings a P&R run logged (change
    adopt-drc-clean-defaults-and-requote, design D5): gpl's target density,
    grt's Metal2 and SRAM Metal5 hold-backs, the stage it stopped after, and
    drt's iteration budget and antenna-repair mode from its status detail.
    The routing lines are read from grt's log, else drt's, as both apply them.
    A log that exists without a hold-back line means the flow's value of the
    time: Metal2 was a fixed 0.30 before it was logged (change drc-clean-pnr),
    and a zero Metal5 share logs nothing. A value is None when no log that
    would carry it exists (its stage was restored), and the drt values are
    None unless drt ended ok."""
    d = Path(d)
    rep = d / "reports"
    rows = pnr_status_rows(d)

    def logged(logs, pattern, unlogged):
        texts = [(rep / f).read_text(errors="replace") for f in logs if (rep / f).exists()]
        if not texts:
            return None
        m = next((m for m in (re.search(pattern, t, re.M) for t in texts) if m), None)
        return m.group(1) if m else unlogged

    routing_logs = ("pnr_grt.log", "pnr_drt.log")
    drt_ok = [detail for stage, status, detail in rows if stage == "drt" and status == "ok"]
    drt = dict(kv.split("=", 1) for kv in (drt_ok[-1] if drt_ok else "").split() if "=" in kv)
    stop = [stage for stage, status, _ in rows if status == "stop-after"]
    return {
        "settings": {
            "gpl density": logged(("pnr_gpl.log",),
                                  r"^Global placement target density: (\S+)$", None),
            "grt Metal2 hold-back": logged(
                routing_logs, r"^Global routing layer adjustment: Metal2 ([^,\s]+),", "0.30"),
            "SRAM Metal5 hold-back": logged(
                routing_logs, r"^SRAM Metal5 adjustment: (\S+) over \d+ regions$", "0"),
            "stop after": stop[-1] if stop else None,
            "drt iteration budget": drt.get("droute_end_iter"),
            "antenna repair": drt.get("antenna"),
        },
        **pnr_routed_outcome(rows),
    }


def pnr_routed_outcome(rows):
    """Detailed routing's outcome from the status rows (sha3-evaluation spec:
    the routed outcome of both runs): drt's last status and detail, the
    router's final count and iteration count (`drt-violations final=<n>
    iterations=<i>`), and the antenna checker's net and pin counts
    (`drt-antenna nets=<n> pins=<m>`). The counts are None, never zero, when
    there is no routed design: no `drt ok` row, since a drt that timed out
    still logs the count it reached (run 39111124087), or a `none` row."""
    drt = [(status, detail) for stage, status, detail in rows
           if stage == "drt" and status != "stop-after"]
    routed = any(status == "ok" for status, _ in drt)
    viol = [(status, detail) for stage, status, detail in rows
            if stage == "drt-violations" and status.startswith("final=")]
    ant = [(status, detail) for stage, status, detail in rows
           if stage == "drt-antenna" and status.startswith("nets=")]
    iters = re.search(r"\biterations=(\d+)", viol[-1][1]) if viol else None
    pins = re.search(r"\bpins=(\d+)", ant[-1][1]) if ant else None
    return {
        "drt_status": drt[-1] if drt else None,
        "drt_violations": int(viol[-1][0][len("final="):]) if routed and viol else None,
        "drt_iterations": int(iters.group(1)) if routed and iters else None,
        "drt_antenna": (int(ant[-1][0][len("nets="):]), int(pins.group(1)))
        if routed and ant and pins else None,
    }


def pnr_same_setting(a, b):
    """Two logged setting values are the same, numerically where both are
    numbers (0.6 and 0.60 agree)."""
    try:
        return float(a) == float(b)
    except (TypeError, ValueError):
        return a == b


def pnr_placement_facts(rep, dpl_log, cts_log):
    """Die line, legalizer and the stages whose gated check_placement passed
    (change use-diamond-legalizer), from a P&R run's stage logs. Runs from
    before that change have neither the die nor the legality lines."""
    floorplan = rep / "pnr_floorplan.log"
    die = re.search(r"^Die: (.+)$", floorplan.read_text(errors="replace"), re.M) \
        if floorplan.exists() else None
    legalizer = re.search(r"^Legalizer: (\S+?),", dpl_log, re.M)
    return {
        "die": die.group(1).strip() if die else None,
        "legal": {s for s, log in (("dpl", dpl_log), ("cts", cts_log))
                  if re.search(rf"^Placement legal after {s}$", log, re.M)},
        "legalizer": legalizer.group(1) if legalizer else None,
    }


def pnr_uniform_power(rpt):
    """Power (W) per report_power group (Sequential, Combinational, Clock,
    Macro, Pad, Total) of grt's report under the lane's uniform activity
    (change pin-soc-power-activity), or None when the report has no such
    section, e.g. a run from before that change."""
    if not rpt.exists():
        return None
    m = re.search(r"^activity: uniform .*?^Total\s+\S+\s+\S+\s+\S+\s+\S+[^\n]*\n",
                  rpt.read_text(errors="replace"), re.M | re.S)
    if not m:
        return None
    return {g: float(w) for g, w in
            re.findall(r"^(\w+)\s+\S+\s+\S+\s+\S+\s+(\S+)\s+[\d.]+%$", m.group(0), re.M)}


def pnr_worst_path(rpt):
    """(startpoint, endpoint, slack) of the most negative path in grt's
    `report_checks -path_delay max` section (one path per group), or None."""
    if not rpt.exists():
        return None
    text = rpt.read_text(errors="replace")
    m = re.search(r"report_checks -path_delay max\n(.*?)(?:^\S+ report_|\Z)", text, re.M | re.S)
    if not m:
        return None
    paths = re.findall(r"^Startpoint: (\S+).*?^Endpoint: (\S+).*?^\s+(-?[\d.]+)\s+slack \(",
                       m.group(1), re.M | re.S)
    return min(((a, b, float(c)) for a, b, c in paths), key=lambda p: p[2], default=None)


SHA3_INSTANCES = ("i_keccak_cvxif", "i_keccak_mmio")


def sha3_instance(path):
    """The SHA-3 instance a worst path starts or ends in, or None."""
    return next((i for i in SHA3_INSTANCES if path and (i in path[0] or i in path[1])), None)


def pnr_clock_buffers(cts_log):
    """Clock buffers CTS created over all clock nets (CTS-0018), or None."""
    n = re.findall(r"CTS-0018\]\s+Created (\d+) clock buffers", cts_log)
    return sum(map(int, n)) if n else None


def pnr_run_problems(m, name):
    """What keeps one P&R run out of a comparison: a stage without a passed
    legality check, overlapping cells, or no die line."""
    errors = [f"{name}: no 'Placement legal after {s}'"
              for s in ("dpl", "cts") if s not in m["legal"]]
    if m["cts_overlaps"]:
        errors.append(f"{name}: {m['cts_overlaps']:,} overlapping cells after cts")
    if not m["die"]:
        errors.append(f"{name}: no 'Die:' line in pnr_floorplan.log")
    return errors


def pnr_comparable(run, ref, run_id, ref_id):
    """Why the two P&R runs cannot be compared, one line per item, or [] when
    they can (sha3-evaluation spec: legal placement after dpl and cts on both
    sides, on the same die, with the same flow inputs). The drt settings are
    compared only when both runs' drt ended ok: a run whose drt failed keeps
    its grt figures comparable (design D4), and says it has no routed design."""
    errors = (pnr_run_problems(run, f"run {run_id or '?'} (with both arms)")
              + pnr_run_problems(ref, f"run {ref_id or '?'} (reference)"))
    if run["die"] and ref["die"] and run["die"] != ref["die"]:
        errors.append(f"die mismatch: run {run_id or '?'} '{run['die']}' against run "
                      f"{ref_id or '?'} '{ref['die']}'")
    drt_settings = ("drt iteration budget", "antenna repair")
    for k in PNR_SETTINGS:
        a, b = run["settings"][k], ref["settings"][k]
        if k in drt_settings and (a is None or b is None):
            continue
        if not pnr_same_setting(a, b):
            errors.append(f"{k} mismatch: run {run_id or '?'} {a or 'not logged'} against "
                          f"run {ref_id or '?'} {b or 'not logged'}")
    return errors


def pnr_cts_overlaps(cts_log, rpt):
    """Overlapping cells cts's check_placement found, or None when it never
    ran. Every run before change use-diamond-legalizer legalized with
    OpenROAD's negotiation legalizer, which left cells overlapping, and cts
    only warned about it. The log's DPL-0005 count is the total; the JSON
    report caps its markers at max_markers (10000), so it is only the
    fallback."""
    m = re.findall(r"DPL-0005\] Overlap check failed \((\d+)\)", cts_log)
    if m:
        return int(m[-1])
    if not rpt.exists():
        return None
    cats = json.loads(rpt.read_text())["DPL"]["category"]
    return len(cats.get("Overlap_failures", {}).get("violations", []))


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
    sides = (("the reference", ref_repair, ids[1]), ("the run with both arms", repair, ids[0]))
    tried = [f"{name} (run {rid or '?'}, {r['outcome']})" for name, r, rid in sides if r]
    untried = [name for name, r, _ in sides if not r]
    text = "Post-route repair was attempted on " + " and ".join(tried)
    if untried:
        text += f" and therefore not on {untried[0]}"
    return text + (", so every timing figure here is from before it (why: `docs/infra-plan.md` "
                   "Phase 11).")


def pnr_stage_text(latest, repaired, repair, ref_repair, repair_ids, drt_ran=False):
    """The "Stage used" sentence of the P&R section, naming the repair status.
    With drt_ran, detailed routing ran on at least one side after the quoted
    stage, and its outcome is in the table."""
    stage = pnr_stage_head(latest, repaired, repair_ids,
                           "ran after it, with its outcome in the table below" if drt_ran
                           else "was not run")
    if (repair or ref_repair) and not repaired:
        stage += " " + pnr_repair_text(repair, ref_repair, repair_ids)
    return stage


def pnr_stage_head(latest, repaired, repair_ids, route):
    """The "Stage used" sentence without the repair attempts; `route` says
    whether detailed routing ran."""
    if repaired:
        stage = (f"**Stage used: grt_repair**, post-route timing repair resumed from each run's "
                 f"`grt` checkpoint (reference: run {(repair_ids or (None, None))[1] or '?'}; "
                 f"with both arms: run {(repair_ids or (None, None))[0] or '?'}; "
                 "`grt_repair.tcl`'s bounded repair, `-repair_tns 20 -max_buffer_percent 15`). "
                 f"Detailed routing is best-effort and {route}.")
    elif latest == "grt":
        stage = ("**Stage used: grt, before post-route repair**: the lane's gate. `grt_repair` "
                 f"is skipped by default, and detailed routing is best-effort and {route}.")
    else:
        stage = (f"**Stage used: {latest or 'none'}**, the latest stage the run reached "
                 f"(detailed routing is best-effort and {route}).")
    return stage


def pnr_settings_text(run):
    """The flow-settings clause of the P&R section, from the run's logs
    (design D5); pnr_comparable has checked that the reference logged the
    same."""
    st = run["settings"]
    m5 = st["SRAM Metal5 hold-back"]
    parts = [f"`gpl` target density {st['gpl density'] or 'not logged'}",
             f"`grt` Metal2 hold-back {st['grt Metal2 hold-back'] or 'not logged'}",
             "no SRAM Metal5 hold-back" if m5 is not None and float(m5) == 0
             else f"SRAM Metal5 hold-back {m5 or 'not logged'}"]
    antenna = {"jumper": "jumper-only antenna repair", "full": "full antenna repair",
               "skipped": "no antenna repair"}
    if st["drt iteration budget"]:
        a = st["antenna repair"]
        parts.append(f"detailed routing with a {st['drt iteration budget']}-iteration budget "
                     f"(`droute_end_iter`) and {antenna.get(a, f'antenna repair {a}')}")
    stop = st["stop after"]
    parts.append(f"`stop_after={stop}`" if stop else "no `stop_after`, through `final`")
    return ", ".join(parts)


def pnr_routed_text(m):
    """One run's detailed-routing outcome for the table: the router's count
    with its iterations, or that there is no routed design."""
    if m["drt_violations"] is None:
        return pnr_no_route_text(m)
    return f"{m['drt_violations']:,} after {m['drt_iterations'] or '?'} iterations"


def pnr_no_route_text(m):
    """Why a run has no routed design: drt never ran, or how it ended."""
    st = m["drt_status"]
    if not st:
        return "no routed design (`drt` not run)"
    return f"no routed design (`drt {' '.join(x for x in st if x)}`)"


def pnr_antenna_text(m):
    """One run's antenna-checker counts for the table, never a zero for a run
    without them."""
    if m["drt_antenna"] is None:
        return "no antenna count"
    return f"{m['drt_antenna'][0]:,} / {m['drt_antenna'][1]:,}"


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

    stage = pnr_stage_text(latest, repaired, repair, ref_repair, repair_ids,
                           drt_ran=bool(run["drt_status"] or ref["drt_status"]))
    out = [
        "## SoC place and route (task 5.4)",
        "",
        f"P&R lane run {run_id or '?'} (the SoC with both SHA-3 arms, `keccak_cvxif` and "
        f"`keccak_mmio`, R = {soc_rounds_per_cycle()}) against run {ref_id or '?'} (the same "
        "SoC without the SHA-3 hardware: CV-X-IF off, no Keccak instances, no external AXI "
        "subordinate; the reference). Same flow and inputs on both sides: die "
        f"{run['die']}, {run['legalizer'] or '?'} legalizer, placement legal after `dpl` and "
        f"`cts` (the flow's gated `check_placement`), {pnr_settings_text(run)}. "
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
        f"| `drt` router violations | {pnr_routed_text(ref)} | {pnr_routed_text(run)} |",
        f"| antenna violations after `drt` (nets / pins) | {pnr_antenna_text(ref)} | "
        f"{pnr_antenna_text(run)} |",
        "",
    ]
    out += pnr_period_text(pnr_achieved_period(run, period, repair if repaired else None),
                           pnr_achieved_period(ref, period, ref_repair if repaired else None),
                           period, run, ref)
    out += pnr_power_text(run, ref)
    out += pnr_caveat_text(run, ref)
    return out


def pnr_period_text(ach, ref_ach, period, run, ref):
    """The achieved-period paragraph: the WNS move against the reference and
    where each run's worst path lies, naming a SHA-3 instance when it is one."""
    if not ach:
        return []
    caveat = ("" if ach[3] else " It is a figure from before post-route repair, not the "
              "SoC's maximum frequency: post-route repair may close part of the gap from "
              "`cts` to `grt`.")
    where = ""
    if ref_ach:
        where = (f" WNS moves by {ach[2] - ref_ach[2]:+.2f} ns against the reference "
                 f"({ref_ach[2]:.2f} ns).")
    wp, rp = run.get("grt_worst_path"), ref.get("grt_worst_path")
    if wp and ach[1] == "grt" and not ach[3]:
        inst = sha3_instance(wp)
        where += (f" **The SoC's critical path is inside the SHA-3 hardware (`{inst}`)**: "
                  if inst else " The critical path is outside the SHA-3 blocks: ")
        where += f"`{wp[0]}` to `{wp[1]}` ({wp[2]:.2f} ns)."
        if rp:
            where += f" The reference's runs from `{rp[0]}` to `{rp[1]}` ({rp[2]:.2f} ns)."
    return [f"Achieved period: {ach[0]:.2f} ns ({period:.1f} ns minus WNS {ach[2]:.2f} ns "
            f"after {pnr_stage_label(ach[1], ach[3])}), used by the energy section."
            f"{caveat}{where}", ""]


def pnr_caveat_text(run, ref):
    """The caveats paragraph. When the reference is placed more sparsely on the
    shared die and still has more grt demand, it says so as a placement effect."""
    sparser = (ref["dpl_util_pct"] is not None and run["dpl_util_pct"] is not None
               and ref["dpl_util_pct"] < run["dpl_util_pct"])
    fell = (run["grt_demand_pct"] is not None and ref["grt_demand_pct"] is not None
            and run["grt_demand_pct"] < ref["grt_demand_pct"])
    congestion = ""
    if sparser and fell:
        congestion = (f" On the shared die the smaller reference is placed more sparsely "
                      f"({ref['dpl_util_pct']:.1f} % against {run['dpl_util_pct']:.1f} % "
                      "utilization), and its `grt` demand and wirelength come out higher than "
                      "with both arms: a placement effect, not one of the arms.")
    return [f"Caveats: one run each, and placement varies from run to run.{congestion} Area, "
            "power and energy of the SHA-3 blocks themselves come from synthesis (per instance) "
            "and from block-level gate-level power, not from this delta.", ""]


def pnr_power_text(run, ref):
    """The SoC power paragraph: both runs' grt power under the lane's uniform
    activity, comparative only, or why it is not reported."""
    text = ("There is no workload SAIF for the whole SoC, and OpenSTA's default activity does not "
            "converge on it (`docs/infra-plan.md` Phase 17), so SoC workload power is not "
            "reported. The SHA-3 blocks' power is the activity-annotated block power in the "
            "sections above.")
    p, q = run["grt_power_w"], ref["grt_power_w"]
    if not (p and q and "Total" in p and "Total" in q and "Clock" in p and "Clock" in q):
        return [text, ""]
    # Summed from the groups, not Total - Clock: each group carries three
    # significant figures, so the difference of two rounded totals is coarser.
    rest_p, rest_q = (sum(w for g, w in m.items() if g not in ("Total", "Clock"))
                      for m in (p, q))
    bufs = ""
    if run["clock_buffers"] and ref["clock_buffers"]:
        bufs = (f" CTS inserted {ref['clock_buffers']:,} clock buffers in the reference and "
                f"{run['clock_buffers']:,} with both arms.")
    return [
        ("**SoC power under uniform activity (comparative only, not workload power)**, after "
         "`grt`: the lane's `report_power` with one uniform activity on every net (change "
         "`pin-soc-power-activity`; three significant figures per group in the report)."),
        "",
        "| | reference | with both arms | delta |",
        "|---|---:|---:|---:|",
        (f"| total (W) | {q['Total']:.3f} | {p['Total']:.3f} | "
         f"{100 * (p['Total'] / q['Total'] - 1):+.1f} % |"),
        (f"| clock network (W) | {q['Clock']:.3f} | {p['Clock']:.3f} | "
         f"{100 * (p['Clock'] / q['Clock'] - 1):+.1f} % |"),
        (f"| everything but the clock network (W) | {rest_q:.3f} | {rest_p:.3f} | "
         f"{100 * (rest_p / rest_q - 1):+.1f} % |"),
        "",
        ("Only the non-clock delta is attributed to the SHA-3 arms. The clock network is "
         "whatever tree CTS built for each placement, and both sides share one fixed die, so "
         "the clock tree follows how densely each netlist is placed rather than the arms."
         f"{bufs} " + text),
        "",
    ]


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
                    "bounded-grt-repair-measurement)")
    ap.add_argument("--pnr-ref-repair", help="pnr-reports artifact dir of the post-route repair "
                    "run that resumed --pnr-ref's grt checkpoint; may be given alone when the "
                    "other side's repair was not attempted")
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
    if (a.pnr_repair or a.pnr_ref_repair) and not a.pnr:
        sys.exit("sha3_ppa: --pnr-repair and --pnr-ref-repair need --pnr and --pnr-ref")
    pnr_run = pnr_metrics(a.pnr) if a.pnr else None
    pnr_ref = pnr_metrics(a.pnr_ref) if a.pnr_ref else None
    if pnr_run:
        errors = pnr_comparable(pnr_run, pnr_ref, a.pnr_run_id, a.pnr_ref_run_id)
        if errors:
            sys.exit("sha3_ppa: the P&R runs are not comparable:\n  " + "\n  ".join(errors))
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
        out += pnr_section(pnr_run, pnr_ref, a.pnr_run_id, a.pnr_ref_run_id,
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
