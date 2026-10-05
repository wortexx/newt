# Copyright 2026 Kyiv School of Economics.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Activity-annotated power of a standalone hw/coproc block netlist
# (block-synth.mk power flow; openspec change sha3-cvxif-coprocessor task 5.2,
# design D8). Reads the SAIF recorded by gate-level simulation of the same
# netlist, so net names match and annotation is direct. Prints the annotated
# fraction and the power report. Typical corner, one clock on clk_i at
# BLOCK_PERIOD_NS.

source [file join [file dirname [info script]] yosys_common.tcl]

read_liberty "${tech_cells}"
read_verilog $netlist
link_design $top_design

set period $::env(BLOCK_PERIOD_NS)
create_clock -name clk -period $period [get_ports clk_i]

puts "BLOCK_POWER period_ns $period"
puts "BLOCK_POWER saif $::env(BLOCK_SAIF) scope $::env(BLOCK_SAIF_SCOPE)"
read_saif -scope $::env(BLOCK_SAIF_SCOPE) $::env(BLOCK_SAIF)
report_activity_annotation
report_power -digits 6
