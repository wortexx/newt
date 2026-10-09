# Copyright 2026 Kyiv School of Economics.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# SoC power probe on a synthesized netlist (docs/infra-plan.md Phase 17;
# openspec/changes/pin-soc-power-activity design D2). Needs no placement:
# reads the netlist with the flow's own init_tech.tcl and SDC and reports
#
#   1. power under OpenSTA's propagated default activity, with one
#      `power_activity: Pass N` line per propagation pass. On this SoC the
#      propagation stops at its 50-pass cap without converging, so this
#      number is a diagnostic, not a power figure;
#   2. per-instance power under that default activity, into $OUT/inst.txt
#      (~100 MB; summed per module by scripts/soc_power_agg.py);
#   3. the lane's own report_metrics into $OUT/soc_power_probe.rpt, whose
#      power section uses the uniform activity every P&R stage reports;
#   4. default-activity power again, which must match (1): report_metrics
#      leaves no activity setting behind.
#
# Run from target/ihp13/openroad (the SDC sources src/... relatively), e.g.
# through `make soc-power-probe NETLIST=...` (openroad.mk). Env: NETLIST
# (required), OUT (required), PDK (default ../pdk).

set netlist     $::env(NETLIST)
set out_dir     $::env(OUT)
set pdk_dir     [expr {[info exists ::env(PDK)] ? $::env(PDK) : "../pdk"}]
set openroad_dir [pwd]
set report_dir  $out_dir

file mkdir $out_dir
source scripts/init_tech.tcl
source scripts/reports.tcl

read_verilog $netlist
link_design iguana_chip
read_sdc src/basilisk.sdc

puts "=== default activity (diagnostic, not a power figure)"
sta::set_debug power_activity 1
report_power -corner tt -digits 4
sta::set_debug power_activity 0

puts "=== per-instance default-activity power -> $out_dir/inst.txt"
report_power -corner tt -digits 6 -instances [get_cells *] > $out_dir/inst.txt

puts "=== report_metrics (uniform activity) -> $out_dir/soc_power_probe.rpt"
report_metrics soc_power_probe false
puts [exec grep -A 16 "report_power tt" $out_dir/soc_power_probe.rpt]

puts "=== default activity again (must match the first report)"
report_power -corner tt -digits 4
puts "=== done"
