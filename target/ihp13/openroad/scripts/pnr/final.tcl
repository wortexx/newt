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
    # Same non-fatal treatment as cts.tcl - see its comment for why
    # (DPL-0033, read-only validation, congestion-bound design already
    # known/accepted). This stage is best-effort already (past the grt
    # gate), but a caught, reported violation is more informative than an
    # uncaught one that just marks the whole stage "failed".
    utl::report "Check placement"
    if { [catch { check_placement -report_file_name ${report_dir}/${proj_name}_final_check_placement.rpt } checkErr] } {
        utl::report "WARNING: check_placement reported violations (non-fatal, see ${report_dir}/${proj_name}_final_check_placement.rpt): $checkErr"
    }
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
