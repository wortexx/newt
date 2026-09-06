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
    # -congestion_iterations 80->20->14, -verbose kept (task 2.4/3.2 real
    # bring-up, third data point): the first two unattended attempts ran
    # their full timeouts (4h, then 8h) with zero progress visibility.
    # Adding -verbose showed why: ~7h of initial routing before the "extra
    # iteration" congestion loop starts, then ~15min/iteration on average -
    # extrapolated, the original 80 was a ~27h+ total run, so it was cut to
    # 20 (~11-13h expected).
    #
    # The first real pnr.yml run at 20 iterations (PNR_TIMEOUT_GRT=57600,
    # 16h) still timed out - but the real per-iteration log data (GRT-0102
    # lines, no timestamps between them) showed iterations 1-14 all
    # completed back-to-back with zero congestion-repair work logged
    # (trivial), then iteration 15 itself triggered a cascade of "Disabled
    # NDR" (GRT-0273) warnings across 63+ clock nets that never finished -
    # "Start extra iteration 16/20" never appeared even after ~10h+ inside
    # iteration 15 alone. This isn't generic slowness a bigger timeout
    # would fix - it's iteration 15 specifically (at whatever congestion
    # state exists after 14 real rounds) hitting a relaxation cascade with
    # no observed sign of terminating. Cut to 14 to stop before ever
    # entering it, rather than gambling more VM time on a step that never
    # completed once. -allow_congestion (unchanged from chip.tcl, which had
    # no external timeout to race against) means stopping at 14 accepts
    # whatever congestion remains rather than erroring - a more-congested
    # result for drt.tcl (already best-effort, already congestion-bound by
    # design.md/docs) to deal with downstream, not a worse-than-nothing one.
    # PNR_TIMEOUT_GRT stays 57600 (16h) - plenty of margin now that the
    # pathological iteration is excluded.
    global_route -guide_file ${report_dir}/${proj_name}_route.guide \
        -congestion_report_file ${report_dir}/${proj_name}_congestion.rpt \
        -congestion_iterations 14 \
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
