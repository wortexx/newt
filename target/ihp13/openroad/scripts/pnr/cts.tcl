# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Stage 5/9: cts - clock tree synthesis + post-CTS setup repair, adapted
# from ../chip.tcl's "CLOCK TREE SYNTHESIS" section
# (openspec/changes/ci-pnr-lane/design.md D1).
#
# Loads dpl.tcl's checkpoint. Re-derives clock dont-touch only to lift it
# again immediately (`unset_dont_touch`), matching chip.tcl's own order:
# clock nets are protected through placement, then freed right before CTS
# so cell insertion/buffering can touch them. Pad dont-touch and
# dont_use_cells remain active from here through drt.tcl.

source [file join [file dirname [info script]] common.tcl]

set err [catch {
    pnr_load ${proj_name}.dpl

    pnr_set_pad_dont_touch
    set clock_nets [pnr_set_clock_dont_touch]
    pnr_set_dont_use

    unset_dont_touch $clock_nets
    utl::report "Repair clock inverters"
    repair_clock_inverters

    utl::report "Clock Tree Synthesis"
    set_wire_rc -clock -layer Metal4
    clock_tree_synthesis -buf_list $ctsBuf -root_buf $ctsBufRoot \
                         -sink_clustering_enable \
                         -obstruction_aware

    # Repair wire length between clock pad and clock-tree root
    utl::report "Repair clock nets"
    repair_clock_nets

    source src/basilisk_postcts.sdc

    # legalize cts cells
    utl::report "Detailed placement"
    detailed_placement
    utl::report "Estimate parasitics"
    estimate_parasitics -placement

    # repair all setup timing
    report_metrics "${proj_name}.cts_unrepaired"

    utl::report "Repair setup"
    repair_timing -setup -skip_pin_swap -verbose -repair_tns 90
    # place inserted cells
    utl::report "Detailed placement"
    detailed_placement
    utl::report "Check placement"
    check_placement -verbose

    utl::report "Estimate parasitics"
    estimate_parasitics -placement
    report_cts -out_file ${report_dir}/${proj_name}.cts.rpt
    report_metrics "${proj_name}.cts"
    save_checkpoint ${proj_name}.cts
    report_image "${proj_name}.cts" true false true
} errMsg]

if { $err } {
    pnr_status cts failed $errMsg
    utl::report "ERROR in cts stage: $errMsg"
    exit 1
} else {
    pnr_status cts ok
    exit 0
}
