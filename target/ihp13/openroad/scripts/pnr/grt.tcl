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
    # -congestion_iterations 80->20, -verbose kept (task 2.4 real bring-up,
    # second data point): the first unattended attempt ran the full
    # PNR_TIMEOUT_GRT=14400s (4h) default at ~99.9% CPU with zero visibility
    # into progress and got killed. Adding -verbose (kept from that attempt)
    # revealed why on the retry (PNR_TIMEOUT_GRT=28800s/8h, also killed):
    # ~6h51m of initial routing/NDR-disable work before the "extra
    # iteration" congestion loop even starts, then each of the 80 requested
    # iterations itself took 9-23min (~15min avg, GRT-0102 "Start extra
    # iteration N/80" log lines) - extrapolated, 80 iterations is a ~27h+
    # total run, not the few-hour budget either timeout attempt gave it.
    # -allow_congestion (unchanged from chip.tcl, which had no external
    # timeout to race against and could just let this run for a day) means
    # it can still stop early and accept an imperfect solution, so capping
    # the iteration count doesn't risk a worse-than-nothing result, just a
    # more-congested one for drt.tcl (already best-effort, already
    # congestion-bound by design.md/docs) to deal with downstream - it caps
    # this gate stage to a viable ~11-13h (7h setup + 20*~15min), run under
    # PNR_TIMEOUT_GRT=57600 (16h) for margin.
    global_route -guide_file ${report_dir}/${proj_name}_route.guide \
        -congestion_report_file ${report_dir}/${proj_name}_congestion.rpt \
        -congestion_iterations 20 \
        -allow_congestion \
        -verbose

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
