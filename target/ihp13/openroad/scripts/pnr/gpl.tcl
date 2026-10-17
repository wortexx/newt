# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Stage 3/9: gpl - global placement (two passes) + pre-placement setup
# repair, adapted from ../chip.tcl's "GLOBAL PLACEMENT" section
# (openspec/changes/ci-pnr-lane/design.md D1).
#
# Re-applies pad/clock dont-touch and dont_use_cells (still active at this
# point in chip.tcl's own flow - not lifted until cts.tcl) and the wire_rc
# setting remove_buffers.tcl's stage used, since none of these survive
# load_checkpoint.

source [file join [file dirname [info script]] common.tcl]

set err [catch {
    pnr_load ${proj_name}.pre_place

    set_wire_rc -clock -layer Metal4
    set_wire_rc -signal -layer Metal4
    pnr_set_pad_dont_touch
    set clock_nets [pnr_set_clock_dont_touch]
    pnr_set_dont_use

    utl::report "Global placement target density: $pnr_gpl_density"
    utl::report "Global placement keep_resize_below_overflow (pass 2): $pnr_gpl_keep_resize"
    utl::report "Cell padding: $pnr_cell_pad_sites sites"

    # -density and pass 2's -keep_resize_below_overflow are passed at each
    # call, from common.tcl.
    #
    # Routability inflation 2.5 in both passes (upstream's 2024 tuning had
    # 1.2, which capped it at x1.2: about +1 % area per routability
    # iteration, never reaching its target). With the macro margins blocked
    # (keep-cells-out-of-macro-margins), 1.2 let the displaced cells pile
    # into the SPI host corner and tripled grt overflow (run 38254112819:
    # 603,825 edges against 198,046); 2.5 brought it to 74,776, WNS at grt
    # -8.96 ns against -13.12 (run 38395368038; docs/infra-plan.md Phase 11).
    set GPL_ARGS {  -routability_driven
                    -routability_check_overflow 0.40
                    -routability_inflation_ratio_coef 2.5
                    -routability_max_inflation_ratio 2.5
                    -max_phi_coef 1.04 }

    set GPL2_ARGS { -routability_driven
                    -routability_check_overflow 0.60
                    -routability_inflation_ratio_coef 2.5
                    -routability_max_inflation_ratio 2.5
                    -timing_driven
                    -max_phi_coef 1.02 }

    # rough placement to get parasitics for steiner-tree so we can run repair_timing
    utl::report "Global Placement (1)"
    global_placement -density $pnr_gpl_density {*}[pnr_gpl_pad_args] {*}$GPL_ARGS
    report_metrics "${proj_name}.gpl"
    report_image "${proj_name}.gpl" true true
    save_checkpoint ${proj_name}.gpl

    utl::report "Estimate parasitics"
    estimate_parasitics -placement
    utl::report "Repair design"
    save_checkpoint ${proj_name}.gpl_fix
    repair_design -verbose
    utl::report "Repair setup"
    repair_timing -setup -skip_pin_swap -verbose -repair_tns 70

    save_checkpoint ${proj_name}.gpl_repaired

    # actual global placement
    utl::report "Global Placement (2)"
    global_placement -density $pnr_gpl_density {*}[pnr_gpl_pad_args] \
        -keep_resize_below_overflow $pnr_gpl_keep_resize {*}$GPL2_ARGS
    report_metrics "${proj_name}.gpl2"
    report_image "${proj_name}.gpl2" true true
    save_checkpoint ${proj_name}.gpl2
} errMsg]

if { $err } {
    pnr_status gpl failed $errMsg
    utl::report "ERROR in gpl stage: $errMsg"
    exit 1
} else {
    pnr_status gpl ok
    exit 0
}
