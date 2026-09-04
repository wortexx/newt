# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Stage 6/9: grt - global routing, adapted from ../chip.tcl's "GLOBAL
# ROUTE" section (openspec/changes/ci-pnr-lane/design.md D1/D4).
#
# This is the last **gated** stage (design D4 / specs/pnr-flow: success is
# gated through global route). run_pnr.sh exits non-zero if this stage
# fails; grt_repair.tcl, drt.tcl, and final.tcl that follow are all
# best-effort and never flip the overall exit code.
#
# Pad dont-touch and dont_use_cells are still active here (never lifted
# after cts.tcl); clock dont-touch stays lifted.

source [file join [file dirname [info script]] common.tcl]

set err [catch {
    pnr_load ${proj_name}.cts

    pnr_set_pad_dont_touch
    pnr_set_dont_use
    pnr_apply_routing_layers

    utl::report "Global route"
    # -verbose added (task 2.4 real bring-up): the first unattended attempt
    # ran the full PNR_TIMEOUT_GRT=14400s (4h) default at ~99.9% CPU with no
    # sign of hanging, then got killed by the timeout wrapper with zero
    # visibility into per-iteration congestion progress - global_route
    # wasn't printing anything between "Global route" and either finishing
    # or being killed. This design is congestion-bound (63-65% utilization;
    # docs/infra-plan.md already accepts this), so -congestion_iterations 80
    # -allow_congestion (unchanged from chip.tcl, which had no external
    # timeout to race against) may simply need more than 4h wall time here -
    # -verbose gives real per-iteration telemetry to judge that, instead of
    # guessing blind before adjusting either the timeout or the iteration
    # count further.
    global_route -guide_file ${report_dir}/${proj_name}_route.guide \
        -congestion_report_file ${report_dir}/${proj_name}_congestion.rpt \
        -congestion_iterations 80 \
        -allow_congestion \
        -verbose
    # default params but -allow_congestion
    # it goes on even if it didn't find a solution (may be able to fix afterwards)

    utl::report "Estimate parasitics"
    estimate_parasitics -global_routing
    report_metrics "${proj_name}.grt"
    save_checkpoint ${proj_name}.grt
    report_image "${proj_name}.grt" true false false true
} errMsg]

if { $err } {
    pnr_status grt failed $errMsg
    utl::report "ERROR in grt stage: $errMsg"
    exit 1
} else {
    pnr_status grt ok
    exit 0
}
