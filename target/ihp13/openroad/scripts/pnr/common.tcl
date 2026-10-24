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

# Global-placement starting target density, used by both passes in gpl.tcl.
# It is only the starting point: routability mode inflates it and
# timing-driven mode resizes it during placement. 0.65 is the upstream value;
# 0.72 was tried and made legalization worse (run 37037836332,
# docs/infra-plan.md Phase 11). Default 0.50: together with die scale 1.25,
# probe P2 (run 38931700180) halved detailed routing's iteration-0
# violations against 1.10 / 0.65 and cut grt overflow from 74,776 to 354,
# and the chain it started (runs 39696194006, 39906592139) routed to 8
# violations (openspec/changes/adopt-drc-clean-defaults-and-requote design
# D1). PNR_GPL_DENSITY overrides it for an experiment without a commit
# (openspec/changes/raise-gpl-density-target design D1).
if { [info exists ::env(PNR_GPL_DENSITY)] && $::env(PNR_GPL_DENSITY) ne "" } {
    set pnr_gpl_density $::env(PNR_GPL_DENSITY)
} else {
    set pnr_gpl_density 0.50
}

# Die scale for the floorplan (floorplan_ring_*way.tcl): the core's width and
# height relative to the taped-out Basilisk die (6230 x 5478 um), pad and
# power-ring margins unchanged. Default 1.25 (core 40.29 M um^2). On the
# taped-out die (1.0) the SoC with both SHA-3 arms reaches 71.3 %
# utilization after CTS, and the diamond legalizer leaves cells unplaced
# there even with a 1000 um window (run 38087884024). At 1.10, the user's
# call on 2026-10-12 (use-diamond-legalizer design D7), dpl and cts legalize
# at 56-59 % utilization (run 38094932339), but the layout does not route
# (715,558 violations after iteration 5, run 38473439796). At 1.25 with
# gpl density 0.50 it is 45 % after cts (probe P2, run 38931700180), and
# that chain routed to 8 violations (run 39906592139;
# openspec/changes/adopt-drc-clean-defaults-and-requote design D1). P&R
# figures are then for the enlarged floorplan, not the taped-out chip, and a
# reference run needs the same setting before any comparison. PNR_DIE_SCALE
# overrides it; 1.0 is the taped-out die (docs/infra-plan.md Phase 11).
if { [info exists ::env(PNR_DIE_SCALE)] && $::env(PNR_DIE_SCALE) ne "" } {
    set pnr_die_scale $::env(PNR_DIE_SCALE)
} else {
    set pnr_die_scale 1.25
}

# Overflow below which gpl's timing-driven iterations keep their
# repair_design changes (global_placement -keep_resize_below_overflow), in
# the second, timing-driven pass. OpenROAD's default, 1.0, keeps them all: the
# second iteration then inserts ~1.1 mm^2 of buffers into a placement still
# at overflow ~0.2, the target density jumps (0.90 / 0.99 / 1.04 in the runs
# on record), Nesterov diverges and reverts, and gpl ends unconverged with
# 80-220 k illegal cells for dpl's legalizer. 0 makes every timing-driven
# iteration virtual: it re-weights nets for timing but inserts nothing. The
# real repair_design / repair_timing between the two passes is unchanged
# (design D1). PNR_GPL_KEEP_RESIZE overrides it; 1.0 restores the old flow.
if { [info exists ::env(PNR_GPL_KEEP_RESIZE)] && $::env(PNR_GPL_KEEP_RESIZE) ne "" } {
    set pnr_gpl_keep_resize $::env(PNR_GPL_KEEP_RESIZE)
} else {
    set pnr_gpl_keep_resize 0
}

# Legalizer for every detailed_placement call (pnr_detailed_placement below).
# OpenROAD 2c56926 defaults to its negotiation legalizer, which never
# converges on this design: it returns with DPL-0701 and 15-24 k violations
# left, in dpl and in both cts passes, and every run on record reached grt on
# an illegal placement. drt then aborted on it with DRT-0218 (run
# 37996272102; docs/infra-plan.md Phase 11). `diamond` selects the classic
# legalizer (-use_diamond_legalizer), the one the 2024 tapeout used: it
# places every cell or fails the call. `negotiation` restores OpenROAD's
# default. PNR_DPL_LEGALIZER overrides it
# (openspec/changes/use-diamond-legalizer design D1/D2).
if { [info exists ::env(PNR_DPL_LEGALIZER)] && $::env(PNR_DPL_LEGALIZER) ne "" } {
    set pnr_dpl_legalizer $::env(PNR_DPL_LEGALIZER)
} else {
    set pnr_dpl_legalizer diamond
}
if { $pnr_dpl_legalizer ni {diamond negotiation} } {
    error "PNR_DPL_LEGALIZER='$pnr_dpl_legalizer' is not a legalizer: use diamond or negotiation"
}

# Search window for every legalization, as detailed_placement
# -max_displacement in microns: one value for both directions or "x y".
# Default "1000 1000" (+/- 2083 sites, +/- 264 rows here): OpenROAD's own
# window (+/- 500 sites, +/- 100 rows) left 3,719 cells unplaced in cts's
# first legalization at 71.3 % utilization (run 38071835792, DPL-0036), and
# the run that legalized every stage used 1000 (run 38094932339). "openroad"
# passes no flag, keeping OpenROAD's own window. DPL-0005 logs the window
# used, in sites and rows. PNR_DPL_MAX_DISPLACEMENT overrides it
# (use-diamond-legalizer design D7).
if { [info exists ::env(PNR_DPL_MAX_DISPLACEMENT)] && [string trim $::env(PNR_DPL_MAX_DISPLACEMENT)] ne "" } {
    set pnr_dpl_max_displacement [string trim $::env(PNR_DPL_MAX_DISPLACEMENT)]
} else {
    set pnr_dpl_max_displacement {1000 1000}
}
if { $pnr_dpl_max_displacement eq "openroad" } {
    set pnr_dpl_max_displacement {}
}
if { [llength $pnr_dpl_max_displacement] == 1 } {
    set pnr_dpl_max_displacement [list $pnr_dpl_max_displacement $pnr_dpl_max_displacement]
}
if { $pnr_dpl_max_displacement ne {} &&
     ([llength $pnr_dpl_max_displacement] != 2 ||
      ![regexp {^[0-9]+ [0-9]+$} [join $pnr_dpl_max_displacement " "]]) } {
    error "PNR_DPL_MAX_DISPLACEMENT='$::env(PNR_DPL_MAX_DISPLACEMENT)' is not a window: use one or two non-negative integers (microns)"
}

# Bridge wrong-direction route guides before detailed routing
# (pnr_bridge_wrong_way_guides below). Global routing can leave a guide that
# spans several gcells against its layer's preferred direction; detailed
# routing's guide graph cannot traverse it, so a pin reachable only through
# it is an island and guide processing aborts with DRT-0218 (run 38094932339,
# clknet_12_3602__leaf..., pin clkbuf_leaf_7247/A; docs/infra-plan.md
# Phase 11). Default 1; PNR_BRIDGE_GUIDES=0 turns it off
# (openspec/changes/bridge-wrong-way-route-guides design D3).
if { [info exists ::env(PNR_BRIDGE_GUIDES)] && $::env(PNR_BRIDGE_GUIDES) ne "" } {
    set pnr_bridge_guides $::env(PNR_BRIDGE_GUIDES)
} else {
    set pnr_bridge_guides 1
}
if { $pnr_bridge_guides ni {0 1} } {
    error "PNR_BRIDGE_GUIDES='$pnr_bridge_guides' is not 0 or 1"
}

# Free sites kept on each side of every standard cell, from global placement
# through legalization (openspec/changes/drc-clean-pnr design D8). On probe
# P2 (run 38931700180) 84 % of detailed routing's violations were on Metal2,
# and holding Metal2 back from global routing only moved them to
# Metal4/Metal5 (run 39006065323): pin access needs free Metal2 tracks next
# to the pins. gpl.tcl passes it to both global_placement passes,
# pnr_detailed_placement sets it before every legalization, so the gated
# check_placement after it checks padding too, and final.tcl clears it
# before filler placement. Each stage is its own process, so it is
# re-applied there rather than trusted to the checkpoint. Default 0, no
# padding; PNR_CELL_PAD_SITES overrides it.
if { [info exists ::env(PNR_CELL_PAD_SITES)] && [string trim $::env(PNR_CELL_PAD_SITES)] ne "" } {
    set pnr_cell_pad_sites [string trim $::env(PNR_CELL_PAD_SITES)]
} else {
    set pnr_cell_pad_sites 0
}
if { ![string is integer -strict $pnr_cell_pad_sites] || $pnr_cell_pad_sites < 0 } {
    error "PNR_CELL_PAD_SITES='$pnr_cell_pad_sites' is not a site count: use a non-negative integer"
}

# Share of Metal2's capacity that global routing holds back
# (set_global_routing_layer_adjustment in pnr_apply_routing_layers below).
# chip.tcl derated Metal2 and Metal3 together by 0.30. On probe P2 (run
# 38931700180) grt then planned Metal2 at 61 % while Metal4/Metal5 sat at
# 39 % / 29 %, and detailed routing left 84 % of its violations on Metal2,
# where pin access already takes many of the tracks. A larger value moves
# global routes up to the layers with room. Metal3 keeps 0.30. Default
# 0.60: from P2's checkpoints, probe P2-M (run 39006065323) cut the
# violations after iteration 1 from 442,669 to 332,259, and its full route
# reached 121 (run 39244019401), at a WNS cost of about 5 ns
# (openspec/changes/adopt-drc-clean-defaults-and-requote design D1).
# PNR_GRT_METAL2_ADJUST overrides it (openspec/changes/drc-clean-pnr design D7).
if { [info exists ::env(PNR_GRT_METAL2_ADJUST)] && [string trim $::env(PNR_GRT_METAL2_ADJUST)] ne "" } {
    set pnr_grt_metal2_adjust [string trim $::env(PNR_GRT_METAL2_ADJUST)]
} else {
    set pnr_grt_metal2_adjust 0.60
}
if { ![string is double -strict $pnr_grt_metal2_adjust] ||
     $pnr_grt_metal2_adjust < 0 || $pnr_grt_metal2_adjust >= 1 } {
    error "PNR_GRT_METAL2_ADJUST='$pnr_grt_metal2_adjust' is not an adjustment: use a number in \[0, 1)"
}

# Share of Metal5's capacity that global routing holds back inside every
# SRAM's footprint (set_global_routing_region_adjustment in
# pnr_apply_routing_layers below). The SRAMs block Metal1-Metal4 and their
# power grid's via stacks leave 8 rows of Metal5 pads over each macro: on
# run 39244019401 only 43 % of the Metal5 tracks there cleared every row,
# yet grt planned up to 22-32 Metal5 nets per gcell column, and detailed
# routing's wrong-way jogs between the pad rows were its last 121
# violations (docs/infra-plan.md, "What is left of DRC, 2026-10-21").
# Default 0.55: with it and jumper-only antenna repair, run 39906592139 cut
# the router's count from 121 to 8 (5 inside an SRAM footprint), at
# grt WNS -12.05 ns against -11.02 ns
# (openspec/changes/adopt-drc-clean-defaults-and-requote design D1). 0 adds
# no region. PNR_GRT_SRAM_METAL5_ADJUST overrides it
# (openspec/changes/drc-clean-sram-metal5-and-antenna design D1).
if { [info exists ::env(PNR_GRT_SRAM_METAL5_ADJUST)] && [string trim $::env(PNR_GRT_SRAM_METAL5_ADJUST)] ne "" } {
    set pnr_grt_sram_metal5_adjust [string trim $::env(PNR_GRT_SRAM_METAL5_ADJUST)]
} else {
    set pnr_grt_sram_metal5_adjust 0.55
}
if { ![string is double -strict $pnr_grt_sram_metal5_adjust] ||
     $pnr_grt_sram_metal5_adjust < 0 || $pnr_grt_sram_metal5_adjust >= 1 } {
    error "PNR_GRT_SRAM_METAL5_ADJUST='$pnr_grt_sram_metal5_adjust' is not an adjustment: use a number in \[0, 1)"
}

# Widest gap between a macro and the core edge that the floorplan blocks for
# placement, in microns (block_macro_core_margins in floorplan_util.tcl). The
# floorplan keeps macros floorPaddingX/Y off the core edge but never cut the
# rows there, so the placer filled the margins with logic walled in by the
# macro: SRAMs obstruct Metal1-Metal4 and their power grid takes most of
# TopMetal1, so those nets crossed the macro on almost nothing or detoured
# through the band outside the core. Run 38094932339 had 6,308 cells there
# and 9,313 nets routed outside the core (docs/infra-plan.md Phase 11). The
# measured gaps are 8.00 um east and west and 14.00 um south and north
# (floorPaddingX/Y from the snapped core edge); 20 covers all four at any
# die scale, since the padding is absolute. 0 turns the blocking off.
# PNR_MACRO_MARGIN_MAX overrides it
# (openspec/changes/keep-cells-out-of-macro-margins design D2).
if { [info exists ::env(PNR_MACRO_MARGIN_MAX)] && [string trim $::env(PNR_MACRO_MARGIN_MAX)] ne "" } {
    set pnr_macro_margin_max [string trim $::env(PNR_MACRO_MARGIN_MAX)]
} else {
    set pnr_macro_margin_max 20
}
if { ![string is double -strict $pnr_macro_margin_max] || $pnr_macro_margin_max < 0 } {
    error "PNR_MACRO_MARGIN_MAX='$pnr_macro_margin_max' is not a width: use a non-negative number (microns)"
}

# Widest channel between two facing macros that dpl's report counts cells in
# (pnr_report_macro_margins below), in microns. Report only: channels keep
# their rows. 40 catches the 30 um channels between the stacked cache-data
# SRAMs, where the lower macro's pins face the channel (5,976 channel
# cells in run 38094932339). PNR_MACRO_CHANNEL_MAX overrides it
# (keep-cells-out-of-macro-margins design D3).
if { [info exists ::env(PNR_MACRO_CHANNEL_MAX)] && [string trim $::env(PNR_MACRO_CHANNEL_MAX)] ne "" } {
    set pnr_macro_channel_max [string trim $::env(PNR_MACRO_CHANNEL_MAX)]
} else {
    set pnr_macro_channel_max 40
}
if { ![string is double -strict $pnr_macro_channel_max] || $pnr_macro_channel_max <= 0 } {
    error "PNR_MACRO_CHANNEL_MAX='$pnr_macro_channel_max' is not a width: use a positive number (microns)"
}

# OpenROAD's per-process default is 1 thread (`threads_ = 1` in
# OpenRoad.cc), and set_thread_count is what feeds STA and the global
# router their thread budgets. chip.tcl set this once globally (line 93)
# for its single long-lived process; the staged port initially carried the
# call into only gpl.tcl and drt.tcl, so every other stage - including
# cts's repair_timing and the whole grt stage - silently ran
# single-threaded (found 2026-09-11 via run 34389061373's logs: exactly
# one ORD-0030 "Using 16 thread(s)" line across all eight stages, matching
# the VM's ~7% CPU telemetry). Same re-derive-per-process class as
# set_wire_rc/estimate_parasitics above. Values above the hardware thread
# count are clamped by OpenROAD itself, so 32 on a 16-vCPU host is fine.
# (The call sits below the source lines so the tclsh substitute check -
# tasks.md 2.1/2.2 - still parses checkpoint.tcl/reports.tcl before
# hitting its first OpenROAD-only command.)

source ${openroad_dir}/scripts/checkpoint.tcl
source ${openroad_dir}/scripts/reports.tcl

set_thread_count $threads

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
# Known risk (design.md Risks, carried over from ci-synth-lane's D4
# addendum): basilisk_instances.sdc's `*ddr_rcv_clk_o*` cell pattern was
# found not to match anything when read_sdc ran against a netlist in the
# yosys/STA-only context. Whether it matches here, against the real
# iguana_chip P&R netlist (not the NO_HYPERBUS Verilator DUT and not
# whatever context the ci-synth-lane run used), is unverified - this is
# exactly what task 2.4's real bring-up run resolves. If it errors here,
# fixing it becomes in-scope per design's Risks table (task 5.3).
# -----------------------------------------------------------------------
proc pnr_read_constraints {} {
    utl::report "Read constraints"
    read_sdc src/basilisk.sdc
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
# and clock routing to Metal2-TopMetal1), with Metal2's reduction from
# pnr_grt_metal2_adjust (default 0.60; chip.tcl's was 0.30), plus the
# Metal5 hold-back over the SRAMs (pnr_apply_sram_metal5_adjustment below).
# Must be re-applied after every
# load_checkpoint that precedes a global_route/detailed_route call in the
# same process, or routing fails with DRT-0155 (guides on TopMetal2) -
# docs/infra-plan.md Appendix B item 4, design D1. Cheap and idempotent;
# every stage from grt.tcl onward calls it before routing.
# -----------------------------------------------------------------------
proc pnr_apply_routing_layers {} {
    global pnr_grt_metal2_adjust
    set_global_routing_layer_adjustment Metal2 $pnr_grt_metal2_adjust
    set_global_routing_layer_adjustment Metal3 0.30
    set_global_routing_layer_adjustment TopMetal1 0.20
    utl::report "Global routing layer adjustment: Metal2 $pnr_grt_metal2_adjust, Metal3 0.30, TopMetal1 0.20"
    pnr_apply_sram_metal5_adjustment
    set_routing_layers -signal Metal2-TopMetal1 -clock Metal2-TopMetal1
}

# Metal5 hold-back over every SRAM (pnr_grt_sram_metal5_adjust, default 0.55;
# 0 = none). Unlike the layer adjustments above, region adjustments accumulate in
# the global router and each one scales the capacity left by the ones before
# it, so the regions are added only on the first call in a process to keep
# this proc idempotent (design D1's task 1.1 check).
set pnr_sram_metal5_regions_added 0
proc pnr_apply_sram_metal5_adjustment {} {
    global pnr_grt_sram_metal5_adjust pnr_sram_metal5_regions_added
    if { $pnr_grt_sram_metal5_adjust == 0 } { return }
    if { $pnr_sram_metal5_regions_added } {
        utl::report "SRAM Metal5 adjustment: $pnr_grt_sram_metal5_adjust already applied in this process"
        return
    }
    set block [ord::get_db_block]
    set dbu [$block getDbUnitsPerMicron]
    set n 0
    foreach inst [$block getInsts] {
        if { ![string match RM_IHP* [[$inst getMaster] getName]] } { continue }
        set bbox [$inst getBBox]
        set_global_routing_region_adjustment \
            [list [expr {double([$bbox xMin]) / $dbu}] [expr {double([$bbox yMin]) / $dbu}] \
                  [expr {double([$bbox xMax]) / $dbu}] [expr {double([$bbox yMax]) / $dbu}]] \
            -layer Metal5 -adjustment $pnr_grt_sram_metal5_adjust
        incr n
    }
    set pnr_sram_metal5_regions_added 1
    utl::report "SRAM Metal5 adjustment: $pnr_grt_sram_metal5_adjust over $n regions"
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

# -----------------------------------------------------------------------
# pnr_detailed_placement: every legalization in the staged flow goes
# through here, so dpl, cts and grt_repair can never disagree about the
# legalizer (use-diamond-legalizer design D1). Logs the legalizer first;
# run_pnr.sh's placement report reads that line from pnr_dpl.log.
# -----------------------------------------------------------------------
proc pnr_detailed_placement {args} {
    global pnr_dpl_legalizer pnr_dpl_max_displacement pnr_cell_pad_sites
    utl::report "Cell padding: $pnr_cell_pad_sites sites"
    if { $pnr_cell_pad_sites > 0 } {
        set_placement_padding -global -left $pnr_cell_pad_sites -right $pnr_cell_pad_sites
    }
    if { $pnr_dpl_max_displacement ne {} } {
        utl::report "Legalizer: $pnr_dpl_legalizer, max displacement $pnr_dpl_max_displacement um"
        lappend args -max_displacement $pnr_dpl_max_displacement
    } else {
        utl::report "Legalizer: $pnr_dpl_legalizer"
    }
    if { $pnr_dpl_legalizer eq "diamond" } {
        lappend args -use_diamond_legalizer
    }
    detailed_placement {*}$args
}

# -----------------------------------------------------------------------
# pnr_gpl_pad_args: global_placement's padding arguments for
# pnr_cell_pad_sites (drc-clean-pnr design D8), so global placement plans for
# the padded widths that legalization will keep. Empty at 0, so the default
# flow passes global_placement exactly the arguments it always had.
# -----------------------------------------------------------------------
proc pnr_gpl_pad_args {} {
    global pnr_cell_pad_sites
    if { $pnr_cell_pad_sites == 0 } {
        return {}
    }
    return [list -pad_left $pnr_cell_pad_sites -pad_right $pnr_cell_pad_sites]
}

# -----------------------------------------------------------------------
# pnr_check_placement: gated legality check after dpl and at the end of cts
# (use-diamond-legalizer design D3). check_placement raises DPL-0033 on any
# overlap, padding or blocked-layer violation; this re-raises it with the
# per-category counts from its JSON report, so the stage's catch records
# them in pnr_status.log and the stage fails before save_checkpoint - no
# checkpoint is ever saved from an illegal placement. The report file stays
# in report_dir for the lane to upload. Counts come from the report's
# markers, which check_placement caps at its max_markers (10000) per
# category; DPL-0005/0010/0011 in the stage log carry the uncapped totals.
# -----------------------------------------------------------------------
proc pnr_check_placement {stage} {
    global report_dir proj_name
    set rpt ${report_dir}/${proj_name}_${stage}_check_placement.rpt
    utl::report "Check placement"
    if { ![catch { check_placement -verbose -report_file_name $rpt } checkErr] } {
        utl::report "Placement legal after $stage"
        return
    }
    error "illegal placement after ${stage}: [pnr_placement_violations $rpt] ($checkErr; see [file tail $rpt])"
}

# Per-category marker counts in a check_placement JSON report, as
# "Overlap_failures 9718, Padding_failures 9717, ..."; plain Tcl, since the
# OpenROAD image carries no JSON package. Each marker has exactly one
# "visited" key, and categories are the keys ending in _failures.
proc pnr_placement_violations {rpt} {
    if { ![file exists $rpt] } {
        return "no report written"
    }
    set counts [dict create]
    set category ""
    set fh [open $rpt r]
    while { [gets $fh line] >= 0 } {
        if { [regexp {"([A-Za-z_]+_failures)"\s*:\s*\{} $line -> name] } {
            set category $name
            dict set counts $category 0
        } elseif { $category ne "" && [string match {*"visited"*} $line] } {
            dict incr counts $category
        }
    }
    close $fh
    set parts {}
    dict for {name n} $counts {
        if { $n > 0 } {
            lappend parts "$name $n"
        }
    }
    if { [llength $parts] == 0 } {
        return "no markers in report"
    }
    return [join $parts ", "]
}

# -----------------------------------------------------------------------
# pnr_report_macro_margins: count the standard cells placed where macros
# wall them in, and log them for run_pnr.sh's placement report
# (keep-cells-out-of-macro-margins design D3):
#   Macro margins: <n> cells (gap <= <w> um)
#   Macro channels: <n> cells (gap <= <w> um)
# Margins are the gaps between a BLOCK instance and the core edge, with the
# same geometry block_macro_core_margins (../floorplan_util.tcl) blocks; with
# the blocking off they are still counted, at the default width. Channels are
# the gaps between two facing macros, over the length both sides share. A
# cell counts where its centre lies. Boxes are bucketed into 100 um tiles, so
# the walk over all instances is one dict lookup per cell. Report only: the
# caller must not let it fail the stage.
# -----------------------------------------------------------------------
proc pnr_report_macro_margins {} {
    global pnr_macro_margin_max pnr_macro_channel_max
    set margin_w [expr {$pnr_macro_margin_max > 0 ? $pnr_macro_margin_max : 20}]
    set block [ord::get_db_block]
    set core  [$block getCoreArea]
    set cx0 [$core xMin]; set cy0 [$core yMin]
    set cx1 [$core xMax]; set cy1 [$core yMax]
    set mw [ord::microns_to_dbu $margin_w]
    set chw [ord::microns_to_dbu $pnr_macro_channel_max]

    set macros {}
    foreach inst [$block getInsts] {
        if { [[$inst getMaster] getType] eq "BLOCK" } {
            set bb [$inst getBBox]
            lappend macros [list [$bb xMin] [$bb yMin] [$bb xMax] [$bb yMax]]
        }
    }

    # boxes: list of {kind x0 y0 x1 y1}; the margins, corners included, come
    # from the same proc the floorplan blocks them with.
    global openroad_dir
    source ${openroad_dir}/scripts/floorplan_util.tcl
    set boxes {}
    foreach m $macros {
        foreach {side box} [macro_core_margin_boxes {*}$m $cx0 $cy0 $cx1 $cy1 $mw] {
            lappend boxes [list margin {*}$box]
        }
    }
    foreach a $macros {
        lassign $a ax0 ay0 ax1 ay1
        foreach b $macros {
            lassign $b bx0 by0 bx1 by1
            # b to the right of a, sharing some height
            set gap [expr {$bx0 - $ax1}]
            set lo [expr {max($ay0, $by0)}]; set hi [expr {min($ay1, $by1)}]
            if { $gap > 0 && $gap <= $chw && $lo < $hi } {
                lappend boxes [list channel $ax1 $lo $bx0 $hi]
            }
            # b above a, sharing some width
            set gap [expr {$by0 - $ay1}]
            set lo [expr {max($ax0, $bx0)}]; set hi [expr {min($ax1, $bx1)}]
            if { $gap > 0 && $gap <= $chw && $lo < $hi } {
                lappend boxes [list channel $lo $ay1 $hi $by0]
            }
        }
    }

    set tile [ord::microns_to_dbu 100]
    set grid [dict create]
    foreach box $boxes {
        lassign $box kind x0 y0 x1 y1
        for {set tx [expr {$x0 / $tile}]} {$tx <= $x1 / $tile} {incr tx} {
            for {set ty [expr {$y0 / $tile}]} {$ty <= $y1 / $tile} {incr ty} {
                dict lappend grid "$tx,$ty" $box
            }
        }
    }

    set counts [dict create margin 0 channel 0]
    foreach inst [$block getInsts] {
        if { ![string match CORE* [[$inst getMaster] getType]] || ![$inst isPlaced] } { continue }
        set bb [$inst getBBox]
        set x [expr {([$bb xMin] + [$bb xMax]) / 2}]
        set y [expr {([$bb yMin] + [$bb yMax]) / 2}]
        set key "[expr {$x / $tile}],[expr {$y / $tile}]"
        if { ![dict exists $grid $key] } { continue }
        foreach box [dict get $grid $key] {
            lassign $box kind x0 y0 x1 y1
            if { $x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1 } {
                dict incr counts $kind
                break
            }
        }
    }
    utl::report "Macro margins: [dict get $counts margin] cells (gap <= $margin_w um)"
    utl::report "Macro channels: [dict get $counts channel] cells (gap <= $pnr_macro_channel_max um)"
    return $counts
}

# -----------------------------------------------------------------------
# pnr_bridge_wrong_way_guides: for every guide on routing levels 2-6
# (Metal2-TopMetal1) that spans more than one gcell against its layer's
# preferred direction, add the same rectangle on the adjacent routing level
# whose preferred direction matches (L+1, or L-1 for the top level), with
# the new layer as via layer, as global routing does for plain segments.
# Nothing is removed. Collects first and creates afterwards, so no guide
# list is mutated while it is walked (bridge-wrong-way-route-guides D1/D2).
# -----------------------------------------------------------------------
proc pnr_bridge_wrong_way_guides {} {
    set block [ord::get_db_block]
    set gxs [[$block getGCellGrid] getGridX]
    set gstep [expr {[lindex $gxs 1] - [lindex $gxs 0]}]
    set by_level [dict create]
    foreach l [[$block getTech] getLayers] {
        if { [$l getType] eq "ROUTING" } {
            dict set by_level [$l getRoutingLevel] $l
        }
    }
    set lo 2
    set hi 6
    set adds {}
    set nets 0
    foreach net [$block getNets] {
        set touched 0
        foreach g [$net getGuides] {
            set l [$g getLayer]
            set lvl [$l getRoutingLevel]
            if { $lvl < $lo || $lvl > $hi } {
                continue
            }
            set b [$g getBox]
            if { [$l getDirection] eq "HORIZONTAL" } {
                set wrong [expr {[$b yMax] - [$b yMin] > $gstep}]
            } else {
                set wrong [expr {[$b xMax] - [$b xMin] > $gstep}]
            }
            if { $wrong } {
                set nl [dict get $by_level [expr {$lvl < $hi ? $lvl + 1 : $lvl - 1}]]
                lappend adds [list $net $nl [$b xMin] [$b yMin] [$b xMax] [$b yMax]]
                set touched 1
            }
        }
        incr nets $touched
    }
    foreach a $adds {
        lassign $a net nl x1 y1 x2 y2
        odb::dbGuide_create $net $nl $nl [odb::new_Rect $x1 $y1 $x2 $y2] false
    }
    utl::report "Bridged [llength $adds] wrong-direction guides on $nets nets (gcell step $gstep dbu)"
    return [llength $adds]
}
