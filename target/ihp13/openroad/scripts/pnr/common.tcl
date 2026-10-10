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
# docs/infra-plan.md Phase 11). PNR_GPL_DENSITY overrides it for an
# experiment without a commit (openspec/changes/raise-gpl-density-target
# design D1).
if { [info exists ::env(PNR_GPL_DENSITY)] && $::env(PNR_GPL_DENSITY) ne "" } {
    set pnr_gpl_density $::env(PNR_GPL_DENSITY)
} else {
    set pnr_gpl_density 0.65
}

# Die scale for the floorplan (floorplan_ring_*way.tcl): the core's width and
# height relative to the taped-out Basilisk die (6230 x 5478 um), pad and
# power-ring margins unchanged. Default 1.0, the taped-out die: with
# pnr_gpl_keep_resize 0 it reached grt (run 37108127061, dpl utilization
# 60.8 %). 1.10 (core +21 %, utilization ~55 %) is the fallback if a larger
# netlist stops legalizing in time; the P&R numbers are then for that
# enlarged floorplan, not the taped-out chip (docs/infra-plan.md Phase 11;
# raise-gpl-density-target design D5). PNR_DIE_SCALE overrides it.
if { [info exists ::env(PNR_DIE_SCALE)] && $::env(PNR_DIE_SCALE) ne "" } {
    set pnr_die_scale $::env(PNR_DIE_SCALE)
} else {
    set pnr_die_scale 1.0
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

# -----------------------------------------------------------------------
# pnr_detailed_placement: every legalization in the staged flow goes
# through here, so dpl, cts and grt_repair can never disagree about the
# legalizer (use-diamond-legalizer design D1). Logs the legalizer first;
# run_pnr.sh's placement report reads that line from pnr_dpl.log.
# -----------------------------------------------------------------------
proc pnr_detailed_placement {args} {
    global pnr_dpl_legalizer
    utl::report "Legalizer: $pnr_dpl_legalizer"
    if { $pnr_dpl_legalizer eq "diamond" } {
        lappend args -use_diamond_legalizer
    }
    detailed_placement {*}$args
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
