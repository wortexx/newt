# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Stage 8/10: ant - antenna repair on the global routes, in its own process
# so that run_pnr.sh's per-stage timeout bounds it
# (openspec/changes/finish-antenna-diode-repair design D1). Best-effort, like
# every stage after grt.
#
# Full repair used to run inside drt.tcl and hung there twice, taking the
# routed design with it: run 34389061373 (101 % routing demand) and run
# 39696194006 (46 % utilization), where repair_antennas inserted 18,902
# diodes, its negotiation re-legalization stopped with 9,663 violations
# (DPL-0701) and the stage then logged nothing for ~23 h until drt's 24 h
# timeout. Tcl cannot interrupt a running C++ command, so only a separate
# process can bound it.
#
# Loads grt_repaired.tcl's checkpoint and always saves `ant`, the stage's
# completion checkpoint, whatever the mode:
#
#   skip    (PNR_SKIP_ANTENNA_REPAIR=1) - saves the design unchanged.
#   jumper  (default) - repair_antennas -jumper_only, saved as `ant_jumper`
#           and again as `ant`.
#   full    - the jumper step and `ant_jumper` as above, then
#           repair_antennas -diode_only, saved as `ant`. The jumper result is
#           on disk before the step that can hang, so if this stage fails or
#           times out after it, run_pnr.sh lets drt route `ant_jumper`
#           instead (design D1's fallback).
#
# The diode step re-legalizes the whole design non-incrementally inside
# repair_antennas (detailedPlacement(0, 0, "") on OpenROAD 2c56926971), with
# no way to pass a legalizer. OpenROAD's choice is sticky within a process
# (use_diamond_legalizer_ |= ...), so one incremental pnr_detailed_placement
# call on the already-legal jumper result first makes that internal call
# use the flow's legalizer, diamond by default (design D2). The stage logs
# which one it is; the DPL lines inside repair_antennas must then show no
# `DPL-1102 Legalizing using negotiation legalizer` when it is diamond.
# run_pnr.sh's report_ant_outcome writes the counts (design D3).
#
# With that fixed, run 40399844770 placed the 18,902 diodes in 10.5 s and
# then logged nothing for 3 h 52 m until the 4 h timeout. The diode step's
# incremental reroute (updateDirtyRoutesFastRoute) ran with congestion not
# allowed, so with any overflow left, up to 31 rounds each ripped up and
# rerouted every net crossing an overflowed gcell, and then raised GRT-0232.
# Run A's global route already has 7,153 overflow, which grt.tcl and
# grt_repair.tcl accept with -allow_congestion. So the diode call passes
# -allow_congestion too, and the reroute leaves the existing overflow in
# place (openspec/changes/allow-congestion-in-diode-repair design D1).
# grt::set_verbose 1 makes it log `GRT-0009 rerouting <n> nets`, and the
# stage logs how long the diode step took (design D2). The jumper call
# keeps no flag: with FastRoute it does no reroute.
#
# PNR_ANTENNA_REPAIR_MODE picks jumper or full; empty or unset is jumper.
# Anything else fails the stage before loading the design
# (drc-clean-sram-metal5-and-antenna design D2). PNR_SKIP_ANTENNA_REPAIR=1
# wins over the mode (the P&R lane's antenna_repair=skip).
#
# Guide bridging (pnr_bridge_wrong_way_guides) stays in drt.tcl, right
# before detailed_route, so it sees the guides this stage rewrote.

source [file join [file dirname [info script]] common.tcl]

set skip_antenna [expr {[info exists ::env(PNR_SKIP_ANTENNA_REPAIR)] && $::env(PNR_SKIP_ANTENNA_REPAIR) eq "1"}]

set antenna_mode jumper
if { [info exists ::env(PNR_ANTENNA_REPAIR_MODE)] && [string trim $::env(PNR_ANTENNA_REPAIR_MODE)] ne "" } {
    set antenna_mode [string trim $::env(PNR_ANTENNA_REPAIR_MODE)]
}
if { $antenna_mode ni {full jumper} } {
    pnr_status ant failed "PNR_ANTENNA_REPAIR_MODE='$antenna_mode' is not a repair mode: use jumper or full"
    error "PNR_ANTENNA_REPAIR_MODE='$antenna_mode' is not a repair mode: use jumper or full"
}
if { $skip_antenna } {
    set antenna_mode skipped
}

set err [catch {
    pnr_load ${proj_name}.grt_repaired

    pnr_set_pad_dont_touch
    pnr_set_dont_use
    pnr_apply_routing_layers

    if { $antenna_mode eq "skipped" } {
        utl::report "PNR_SKIP_ANTENNA_REPAIR=1: skipping antenna repair"
    } else {
        utl::report "Antenna repair: jumpers"
        repair_antennas -jumper_only
        save_checkpoint ${proj_name}.ant_jumper

        if { $antenna_mode eq "full" } {
            pnr_detailed_placement -incremental
            if { $pnr_dpl_legalizer eq "diamond" } {
                utl::report "Diode legalization: diamond (sticky from pnr_detailed_placement)"
            } else {
                utl::report "Diode legalization: $pnr_dpl_legalizer (PNR_DPL_LEGALIZER)"
            }
            utl::report "Antenna repair: diodes"
            utl::report "Diode reroute: congestion allowed"
            grt::set_verbose 1
            set diode_t0 [clock seconds]
            # Requires a LEF cell with class 'CORE ANTENNACELL', otherwise
            # the diode cell has to be named.
            repair_antennas -diode_only -allow_congestion
            utl::report "Diode step: [expr {[clock seconds] - $diode_t0}] s (congestion allowed)"
        }
    }

    save_checkpoint ${proj_name}.ant
} errMsg]

if { $err } {
    pnr_status ant failed "$errMsg"
    utl::report "ERROR in ant stage (best-effort, non-fatal to the flow): $errMsg"
    exit 1
} else {
    pnr_status ant ok "antenna=$antenna_mode"
    exit 0
}
