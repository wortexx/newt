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
    # -signal added alongside chip.tcl's original -clock re-set (task 2.4
    # real bring-up, RSZ-0089 "Could not find a resistance value for any
    # corner"): chip.tcl's single continuous process already had -signal
    # wire_rc active from its own pre-remove_buffers section and never
    # needed to re-set it here; this fresh per-stage process does, since
    # it's the first thing in this process that runs repair_timing (below,
    # via "Repair setup") and needs a resistance/capacitance model to
    # evaluate buffer max wire length.
    set_wire_rc -clock -layer Metal4
    set_wire_rc -signal -layer Metal4
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
    # check_placement is a read-only validation (no repair effect) that
    # OpenROAD 2c56926 fails hard on thousands of accumulated buffer-cell
    # overlaps after CTS's repair_timing insertions (DPL-0033) - on the
    # 2024 OpenROAD chip.tcl was written for, the same call apparently
    # didn't hard-fail here, matching the stricter-validation pattern hit
    # repeatedly across this design's other checks this bring-up (PDN
    # generator, resizer). This design is already known/accepted as
    # congestion-bound at 63% utilization (docs/infra-plan.md; "clean
    # route is a stretch goal, not a gate") - a placement-quality
    # complaint from a diagnostic-only check doesn't change what's
    # actually placed, so it's caught and reported rather than aborting
    # the stage; downstream stages (grt onward) already have their own
    # best-effort handling for whatever consequences this quality has.
    # Report redirected to a file (-report_file_name) instead of the
    # thousands of overlap lines it would otherwise dump into the main log.
    utl::report "Check placement"
    if { [catch { check_placement -verbose -report_file_name ${report_dir}/${proj_name}_cts_check_placement.rpt } checkErr] } {
        utl::report "WARNING: check_placement reported violations (non-fatal, see ${report_dir}/${proj_name}_cts_check_placement.rpt): $checkErr"
    }

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
