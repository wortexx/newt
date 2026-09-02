# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Stage 1/9: floorplan (incl. power grid) - adapted from ../chip.tcl's
# read-design-through-power-grid section for the staged unattended flow
# (openspec/changes/ci-pnr-lane/design.md D1). First stage: no predecessor
# checkpoint, reads the netlist directly.
#
# Produces two checkpoints (floorplan, power_grid); run_pnr.sh treats
# power_grid as this stage's completion marker for resume purposes.

source [file join [file dirname [info script]] common.tcl]

set err [catch {
    pnr_init_tech
    pnr_read_design
    pnr_read_constraints

    utl::report "Check constraints"
    check_setup -verbose                                      > ${report_dir}/${proj_name}_checks.rpt
    report_checks -unconstrained -format end -no_line_splits >> ${report_dir}/${proj_name}_checks.rpt
    report_checks -format end -no_line_splits                >> ${report_dir}/${proj_name}_checks.rpt

    utl::report "Create Floorplan"
    if { [info exists ::env(L1CACHE_WAYS)] && $::env(L1CACHE_WAYS) eq "2"} {
        source scripts/floorplan_ring_2way.tcl
    } else {
        source scripts/floorplan_ring_4way.tcl
    }
    save_checkpoint ${proj_name}.floorplan
    report_image "${proj_name}.floorplan" true

    utl::report "Create Power Grid"
    source scripts/power_grid_stripes.tcl
    save_checkpoint ${proj_name}.power_grid
    report_image "${proj_name}.power" true
} errMsg]

if { $err } {
    pnr_status floorplan failed $errMsg
    utl::report "ERROR in floorplan stage: $errMsg"
    exit 1
} else {
    pnr_status floorplan ok
    exit 0
}
