# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Stage 9/9: final - filler placement + DEF export, adapted from
# ../chip.tcl's tail (openspec/changes/ci-pnr-lane/design.md D1/D4).
#
# Best-effort, same as drt.tcl: this stage's outcome never changes the
# flow's overall exit status. Writes out/${proj_name}.final.def, the
# artifact the ci-pnr-lane specs (ci-pipeline: "P&R lane publishes routing
# outputs") require the workflow to upload.

source [file join [file dirname [info script]] common.tcl]

set err [catch {
    pnr_load ${proj_name}.drt

    pnr_set_pad_dont_touch
    pnr_set_dont_use

    utl::report "Filler placement"
    filler_placement sg13g2_fill*
    utl::report "Check placement"
    check_placement
    save_checkpoint ${proj_name}.final
    report_image "${proj_name}.final" true true false true
    utl::report "Write DEF"
    file mkdir out
    write_def out/${proj_name}.final.def
} errMsg]

if { $err } {
    pnr_status final failed $errMsg
    utl::report "ERROR in final stage (best-effort, non-fatal to the flow): $errMsg"
    exit 1
} else {
    pnr_status final ok
    exit 0
}
