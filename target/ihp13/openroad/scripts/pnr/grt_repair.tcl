# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Stage 7/9: grt_repair - post-route timing repair, adapted from
# ../chip.tcl's "REPAIR ROUTED TIMING" (`use_routing_repairs`) section
# (openspec/changes/ci-pnr-lane/design.md D2/D4).
#
# Best-effort: this stage runs after the gate (grt.tcl) and its failure or
# a `PNR_SKIP_GRT_REPAIR=1` skip never changes the overall flow's exit
# status - only drt.tcl's choice of which checkpoint to resume from.
#
# Bounded per design D2 / docs/infra-plan.md Phase 5: every repair_timing
# call here uses `-repair_tns 20 -max_buffer_percent 15` instead of
# chip.tcl's `-repair_tns 100`, which was observed looping effectively
# forever on this design (WNS ~ -2.5 ns, does not close timing). If
# `PNR_SKIP_GRT_REPAIR=1` is set, this script does no repair work at all
# and simply re-saves the grt checkpoint under the grt_repaired name so
# drt.tcl has a single, uniform checkpoint name to load regardless of
# whether this stage ran for real.

source [file join [file dirname [info script]] common.tcl]

set skip_repair [expr {[info exists ::env(PNR_SKIP_GRT_REPAIR)] && $::env(PNR_SKIP_GRT_REPAIR) eq "1"}]

set err [catch {
    pnr_load ${proj_name}.grt

    pnr_set_pad_dont_touch
    pnr_set_dont_use
    pnr_apply_routing_layers

    if { $skip_repair } {
        utl::report "PNR_SKIP_GRT_REPAIR=1: skipping post-route timing repair"
        save_checkpoint ${proj_name}.grt_repaired
    } else {
        grt::set_verbose 0
        # estimate_parasitics before the first repair_design/repair_timing
        # call in this fresh process (task 2.4 real bring-up, same RSZ-0089
        # class as cts.tcl's fix): chip.tcl's continuous process already
        # had global-routing-based parasitics active here, carried over
        # from the immediately preceding GRT section's own
        # estimate_parasitics -global_routing call (matches grt.tcl); this
        # process needs its own, since grt.tcl's checkpoint round-trips
        # physical DB + netlist, not the STA engine's parasitics estimate.
        estimate_parasitics -global_routing
        # Repair design using global route parasitics
        utl::report "Perform buffer insertion..."
        repair_design -verbose

        utl::report "GRT incremental..."
        # Run to get modified net by DPL
        global_route -start_incremental
        # Running DPL to fix overlapped instances
        detailed_placement
        # Route only the modified net by DPL
        global_route -end_incremental \
                    -congestion_report_file ${report_dir}/congestion_repaired_initial.rpt \
                    -guide_file ${report_dir}/${proj_name}_route.guide \
                    -verbose
        report_metrics "${proj_name}.grt_repaired_initial"
        save_checkpoint ${proj_name}.grt_repaired_initial
        report_image "${proj_name}.grt_repair_initial" true true false true

        # Repair timing using global route parasitics
        utl::report "Repair setup and hold violations..."
        estimate_parasitics -global_routing
        repair_timing -skip_pin_swap -recover_power 80 -verbose
        repair_timing -skip_pin_swap -setup -verbose -repair_tns 20 -max_buffer_percent 15
        repair_timing -skip_pin_swap -hold  -verbose -repair_tns 20 -max_buffer_percent 15

        report_metrics "${proj_name}.grt_repaired_timing"
        save_checkpoint ${proj_name}.grt_repaired_timing

        utl::report "GRT (2)..."
        # Running DPL to fix overlapped instances
        detailed_placement
        global_route -guide_file ${report_dir}/${proj_name}_route.guide \
            -congestion_report_file ${report_dir}/${proj_name}_congestion.rpt \
            -congestion_iterations 80
        estimate_parasitics -global_routing
        repair_timing -skip_pin_swap -hold -hold_margin 0.1 -verbose -repair_tns 20 -max_buffer_percent 15
        global_route -start_incremental
        # Running DPL to fix overlapped instances
        detailed_placement
        # Route only the modified net by DPL
        global_route -end_incremental \
                    -congestion_report_file ${report_dir}/congestion_repaired_initial.rpt \
                    -guide_file ${report_dir}/${proj_name}_route.guide \
                    -verbose
        report_metrics "${proj_name}.grt_repaired"
        save_checkpoint ${proj_name}.grt_repaired
        report_image "${proj_name}.grt_repaired" true true false true
    }
} errMsg]

if { $err } {
    pnr_status grt_repair failed $errMsg
    utl::report "ERROR in grt_repair stage (best-effort, non-fatal to the flow): $errMsg"
    exit 1
} else {
    pnr_status grt_repair ok [expr {$skip_repair ? "skipped" : ""}]
    exit 0
}
