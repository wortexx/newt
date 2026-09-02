# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Stage 8/9: drt - antenna repair + detailed routing, adapted from
# ../chip.tcl's tail section (openspec/changes/ci-pnr-lane/design.md D1/D4).
#
# Best-effort per spec (specs/pnr-flow: "Success is gated through global
# route; detailed route is best-effort"): this design is known
# congestion-bound at 63% utilization (docs/infra-plan.md Appendix A) and a
# manual run needed manual stopping after 700k -> 516k DRC violations over
# 2 iterations without converging. `-droute_end_iter` bounds the iteration
# budget so this stage terminates on its own; run_pnr.sh's per-stage
# timeout is the backstop if it still runs long. Always loads
# grt_repaired.tcl's checkpoint - grt_repair.tcl produces that name whether
# or not it actually ran a repair (see its PNR_SKIP_GRT_REPAIR branch), so
# this script never needs to know which case happened.
#
# PNR_DRT_END_ITER overrides the iteration budget (default matches
# chip.tcl's original 40; lower it for a bounded CI run per design D4 -
# the exact value is tuned during task 2.4's real bring-up).

source [file join [file dirname [info script]] common.tcl]

set droute_end_iter 40
if { [info exists ::env(PNR_DRT_END_ITER)] } {
    set droute_end_iter $::env(PNR_DRT_END_ITER)
}

set err [catch {
    pnr_load ${proj_name}.grt_repaired

    pnr_set_pad_dont_touch
    pnr_set_dont_use
    pnr_apply_routing_layers

    # Requires LEF cell with class 'CORE ANTENNACELL', otherwise you need to give a cell
    repair_antennas

    utl::report "Detailed route"
    set_thread_count $threads
    detailed_route -output_drc ${report_dir}/${proj_name}_route_drc.rpt \
                   -bottom_routing_layer Metal2 \
                   -top_routing_layer TopMetal1 \
                   -droute_end_iter $droute_end_iter \
                   -drc_report_iter_step 5 \
                   -clean_patches \
                   -save_guide_updates \
                   -verbose 1

    save_checkpoint ${proj_name}.drt
    report_image "${proj_name}.drt" true false false true
    report_design_area
} errMsg]

# Best-effort stage-detail line for the summary: pull the final DRC
# violation count out of the route-DRC report if it exists, regardless of
# whether the stage above raised a Tcl error.
set drc_detail ""
set drc_report ${report_dir}/${proj_name}_route_drc.rpt
if { [file exists $drc_report] } {
    set drc_count 0
    set fh [open $drc_report r]
    while { [gets $fh line] >= 0 } {
        if { [string match "*violation*" $line] } {
            incr drc_count
        }
    }
    close $fh
    set drc_detail "drc_report_lines=$drc_count"
}

if { $err } {
    pnr_status drt failed "$errMsg $drc_detail"
    utl::report "ERROR in drt stage (best-effort, non-fatal to the flow): $errMsg"
    exit 1
} else {
    pnr_status drt ok "droute_end_iter=$droute_end_iter $drc_detail"
    exit 0
}
