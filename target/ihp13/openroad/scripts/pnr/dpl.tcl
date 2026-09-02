# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Stage 4/9: dpl - detailed placement + mirror optimization, adapted from
# ../chip.tcl's "DETAILED PLACEMENT" section
# (openspec/changes/ci-pnr-lane/design.md D1).
#
# Loads gpl.tcl's final checkpoint (gpl2). Pad/clock dont-touch and
# dont_use_cells are still active here in chip.tcl's own flow (lifted only
# at the start of cts.tcl), so they're re-applied again.

source [file join [file dirname [info script]] common.tcl]

set err [catch {
    pnr_load ${proj_name}.gpl2

    pnr_set_pad_dont_touch
    set clock_nets [pnr_set_clock_dont_touch]
    pnr_set_dont_use

    set DPL_ARGS {}

    utl::report "Detailed placement"
    detailed_placement {*}$DPL_ARGS
    utl::report "Optimize mirroring"
    optimize_mirroring

    utl::report "Estimate parasitics"
    estimate_parasitics -placement
    report_metrics "${proj_name}.dpl"
    save_checkpoint ${proj_name}.dpl
    report_image "${proj_name}.dpl" true true
} errMsg]

if { $err } {
    pnr_status dpl failed $errMsg
    utl::report "ERROR in dpl stage: $errMsg"
    exit 1
} else {
    pnr_status dpl ok
    exit 0
}
