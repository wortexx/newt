# Copyright 2026 Kyiv School of Economics.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# OpenSTA for a standalone hw/coproc block netlist (block-synth.mk): one clock
# on clk_i at BLOCK_PERIOD_NS, zero input/output delay, typical corner. The
# chip's basilisk.sdc does not apply here: it constrains chip pins.

source [file join [file dirname [info script]] yosys_common.tcl]

read_liberty "${tech_cells}"
read_verilog $netlist
link_design $top_design

set period $::env(BLOCK_PERIOD_NS)
create_clock -name clk -period $period [get_ports clk_i]
set_input_delay  0 -clock clk [delete_from_list [all_inputs] [get_ports clk_i]]
set_output_delay 0 -clock clk [all_outputs]

puts "BLOCK_STA period_ns $period"
report_worst_slack -max -digits 4
report_checks -path_delay max -format full -digits 3
report_checks -path_delay max -from [all_registers -clock_pins] -to [all_registers -data_pins] -format end -digits 3
