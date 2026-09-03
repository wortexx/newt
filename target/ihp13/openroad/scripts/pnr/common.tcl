# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Shared prologue for the staged, unattended P&R flow
# (docs/infra-plan.md Phase 5; openspec/changes/ci-pnr-lane/design.md D1).
#
# Unlike scripts/chip.tcl (one long-lived OpenROAD process for the whole
# flow, still used for local/interactive/GUI runs), each stage script in
# this directory is invoked as its own `openroad -exit` process by
# run_pnr.sh. Splitting into one process per stage is what makes a
# `remove_buffers` segfault retryable and a run resumable (see design D1) -
# but it also means every stage after the first starts from a blank STA/GUI
# state and must re-derive everything chip.tcl's single process only ever
# set up once. Concretely, `save_checkpoint`/`load_checkpoint`
# (../checkpoint.tcl) round-trip the OpenROAD physical database (.odb) and
# the netlist (.v) - NOT SDC-derived timing constraints, dont-touch/dont-use
# sets, or global-routing layer configuration. Every stage script sources
# this file, then calls the `pnr_*` procs it needs, in the same order
# chip.tcl established them the first time.

set proj_name    $::env(PROJ_NAME)
set netlist      $::env(NETLIST)
set top_design   $::env(TOP_DESIGN)
set report_dir   $::env(REPORTS)
set save_dir     $::env(SAVE)
set pdk_dir      $::env(PDK)

set stage_dir     [file dirname [file normalize [info script]]]
set scripts_dir   [file dirname $stage_dir]
set openroad_dir  [file dirname $scripts_dir]

set step_by_step_debug 0
set threads 32

source ${openroad_dir}/scripts/checkpoint.tcl
source ${openroad_dir}/scripts/reports.tcl

# -----------------------------------------------------------------------
# pnr_init_tech: read liberty/LEF and define the dont_use_cells/ctsBuf/
# ctsBufRoot/etc. globals init_tech.tcl sets. Every stage needs this -
# LEF/liberty are not part of the .odb checkpoint either. This intentionally
# skips chip.tcl's nonfree-PDK (`../../nonfree/or_init_tech.tcl`) branch:
# that path is for local runs against a proprietary PDK the CI flow never
# has, so the staged flow always uses the open PDK init.
#
# All of `pdk_dir` (read) and `dont_use_cells`/`ctsBuf`/`ctsBufRoot`/
# `iocorner`/`iofill` (set by init_tech.tcl) must be declared `global` here
# - unlike chip.tcl's original top-level `source`, this one runs inside a
# proc, and a bare `source` inside a proc executes the sourced file's code
# in that proc's *local* scope. Without these declarations, init_tech.tcl
# fails immediately (`can't read "pdk_dir": no such variable` - found via
# task 2.4's real bring-up run) and, if it didn't, its outputs would vanish
# the moment this proc returned instead of surviving as real globals.
# -----------------------------------------------------------------------
proc pnr_init_tech {} {
    global openroad_dir pdk_dir dont_use_cells ctsBuf ctsBufRoot iocorner iofill
    source ${openroad_dir}/scripts/init_tech.tcl
}

# -----------------------------------------------------------------------
# pnr_read_design: read the synthesized netlist and link it. Only the first
# stage (floorplan.tcl) calls this - every later stage gets the design back
# via load_checkpoint instead.
# -----------------------------------------------------------------------
proc pnr_read_design {} {
    global netlist top_design
    utl::report "Read netlist"
    read_verilog $netlist
    link_design $top_design
}

# -----------------------------------------------------------------------
# pnr_read_constraints: (re-)read the SDC. Constraints live in the STA
# engine's own state, not the .odb checkpoint, so every stage that runs
# timing-aware commands (repair_design/repair_timing, CTS, global/detailed
# route) must call this after loading its checkpoint - not just the first
# stage, unlike chip.tcl's single `read_sdc` call near its top.
#
# Resolved risk (was: design.md Risks / ci-synth-lane's D4 addendum):
# basilisk_instances.sdc's `*ddr_rcv_clk_o*` cell pattern was found not to
# match anything when read_sdc ran against a netlist in the yosys/STA-only
# context. Confirmed via task 2.4's real bring-up: against the real
# iguana_chip P&R netlist, this pattern DOES match a real cell (the
# serial-link RX clock register) - read_sdc completes cleanly here, no
# fix needed.
#
# Also applies pnr_fixup_sram_max_capacitance (below) - a PDK liberty
# content bug, not something read_sdc itself needs, but applied at the
# same point every stage already re-establishes SDC-level state.
# -----------------------------------------------------------------------
proc pnr_read_constraints {} {
    utl::report "Read constraints"
    read_sdc src/basilisk.sdc
    pnr_fixup_sram_max_capacitance
}

# -----------------------------------------------------------------------
# pnr_fixup_sram_max_capacitance: SDC-level workaround for a genuine PDK
# liberty content bug (docs/infra-plan.md / design.md Risks; found via
# task 2.4's real bring-up). Every SRAM macro's A_DOUT output bus declares
# `max_capacitance : "6.4e-14"` - as picofarads (this library's own
# capacitive_load_unit), 14 orders of magnitude too small (a min buffer's
# own input cap is ~0.001pF) - which trips OpenROAD 2c56926's resizer
# (RSZ-0169) during repair_design/repair_timing. Confirmed against a newer
# upstream PDK release where the same field reads `0.064` (physically
# sensible; matches a units-scale bug in our pinned commit exactly:
# 6.4e-14 Farads == 0.064 picofarads).
#
# Deliberately NOT fixed by bumping the PDK (tried during this same
# bring-up - see design.md Risks: the newer PDK's tech LEF changed several
# routing layers' track pitch, e.g. TopMetal2 2.28um -> 3.28um, which
# broke this design's hand-tuned floorplan/power-grid geometry constants
# in power_grid_stripes.tcl - PDN-0185, a real physical-design re-tuning
# problem well beyond this change's OpenROAD-API-compat scope) and NOT
# fixed by editing the vendored PDK file (third-party content). Overridden
# here instead: an SDC-level `set_max_capacitance` on the actual
# instantiated pins takes precedence over the library-derived value in
# OpenSTA's constraint resolution, so this needs no image/PDK change.
# -----------------------------------------------------------------------
proc pnr_fixup_sram_max_capacitance {} {
    set dout_pins [get_pins -hierarchical -filter "name =~ *A_DOUT*"]
    if {[llength $dout_pins] > 0} {
        set_max_capacitance 0.064 $dout_pins
    }
}

# -----------------------------------------------------------------------
# pnr_set_pad_dont_touch / pnr_set_clock_dont_touch / pnr_set_dont_use:
# the three dont-touch/dont-use sets chip.tcl establishes once (just before
# remove_buffers) and keeps active for most of the rest of the flow -
# pad-net dont-touch and dont_use_cells stay on through detailed route;
# clock-net dont-touch is explicitly lifted again right before CTS
# (chip.tcl's `unset_dont_touch $clock_nets`). Each stage script re-applies
# exactly the subset chip.tcl would have had active at that point; see the
# per-stage comments for which subset that is.
# -----------------------------------------------------------------------
proc pnr_set_pad_dont_touch {} {
    set_dont_touch [get_nets -of_objects [get_pins */PAD]]
}

proc pnr_set_clock_dont_touch {} {
    set clock_nets [get_nets -of_objects [get_pins -of_objects "*_reg" -filter "name == CLK"]]
    set_dont_touch $clock_nets
    return $clock_nets
}

proc pnr_set_dont_use {} {
    global dont_use_cells
    set_dont_use $dont_use_cells
}

# -----------------------------------------------------------------------
# pnr_apply_routing_layers: the GRT layer config from chip.tcl's Global
# Route section (reduce M2/M3/TopMetal1 routing resources, restrict signal
# and clock routing to Metal2-TopMetal1). Must be re-applied after every
# load_checkpoint that precedes a global_route/detailed_route call in the
# same process, or routing fails with DRT-0155 (guides on TopMetal2) -
# docs/infra-plan.md Appendix B item 4, design D1. Cheap and idempotent;
# every stage from grt.tcl onward calls it before routing.
# -----------------------------------------------------------------------
proc pnr_apply_routing_layers {} {
    set_global_routing_layer_adjustment Metal2-Metal3 0.30
    set_global_routing_layer_adjustment TopMetal1 0.20
    set_routing_layers -signal Metal2-TopMetal1 -clock Metal2-TopMetal1
}

# -----------------------------------------------------------------------
# pnr_load: load a named checkpoint and put the process back into a state
# equivalent to "just finished that stage in chip.tcl's single process" -
# tech init, netlist + physical database, and SDC. Callers still need to
# call the dont-touch/dont-use/routing-layer procs above as appropriate for
# the stage they're about to run - pnr_load only covers what every stage
# needs unconditionally.
# -----------------------------------------------------------------------
proc pnr_load {checkpoint_name} {
    pnr_init_tech
    load_checkpoint $checkpoint_name
    pnr_read_constraints
}

# -----------------------------------------------------------------------
# pnr_status: append one line to the driver's machine-readable stage-status
# file (design D5 / tasks.md 2.3): "<stage> <status> [<detail>]", status
# one of ok/failed. run_pnr.sh reads this to build the step-summary table
# without re-parsing OpenROAD logs, and to know whether a gated stage
# actually succeeded (a stage's own exit code is the primary signal; this
# file additionally carries best-effort-stage detail, e.g. drt's DRC count).
# -----------------------------------------------------------------------
proc pnr_status {stage status {detail ""}} {
    global save_dir
    file mkdir $save_dir
    set fileId [open ${save_dir}/pnr_status.log a]
    puts $fileId "$stage $status $detail"
    close $fileId
}
