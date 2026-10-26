# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Stage 9/10: drt - detailed routing, adapted from ../chip.tcl's tail
# section (openspec/changes/ci-pnr-lane/design.md D1/D4).
#
# Best-effort per spec (specs/pnr-flow: "Success is gated through global
# route; detailed route is best-effort"): this design is known
# congestion-bound at 63% utilization (docs/infra-plan.md Appendix A) and a
# manual run needed manual stopping after 700k -> 516k DRC violations over
# 2 iterations without converging. `-droute_end_iter` bounds the iteration
# budget so this stage terminates on its own; run_pnr.sh's per-stage
# timeout is the backstop if it still runs long.
#
# PNR_DRT_END_ITER overrides the iteration budget (default matches
# chip.tcl's original 40; lower it for a bounded CI run per design D4 -
# the exact value is tuned during task 2.4's real bring-up).
#
# Loads ant.tcl's result: `ant` if it exists, otherwise `ant_jumper`, the
# jumper-repaired design ant.tcl saves before its diode step. Antenna repair
# used to run here and hung twice inside repair_antennas' diode step, which
# cost the routed design both times (runs 34389061373 and 39696194006); it
# is now its own bounded stage, and run_pnr.sh only lets this stage run
# without `ant` when `ant_jumper` exists
# (openspec/changes/finish-antenna-diode-repair design D1). The status
# detail records which one was routed (`input=ant|ant_jumper`). The repair
# mode itself (PNR_ANTENNA_REPAIR_MODE, PNR_SKIP_ANTENNA_REPAIR) is ant.tcl's.
#
# After detailed_route, check_antennas counts the routed design's antenna
# violations, whether or not repair ran, and writes
# <proj>_antenna.rpt. run_pnr.sh's report_antenna_outcome takes the
# counts from this stage's log (ANT-0002 nets, ANT-0001 pins); the check is
# reporting only, so its failure is logged and the stage still ends ok
# (design D3).

source [file join [file dirname [info script]] common.tcl]

set droute_end_iter 40
if { [info exists ::env(PNR_DRT_END_ITER)] } {
    set droute_end_iter $::env(PNR_DRT_END_ITER)
}

if { [file exists ${save_dir}/${proj_name}.ant.zip] } {
    set drt_input ant
} else {
    set drt_input ant_jumper
}

set err [catch {
    utl::report "Detailed route input: $drt_input"
    pnr_load ${proj_name}.$drt_input

    pnr_set_pad_dont_touch
    pnr_set_dont_use
    pnr_apply_routing_layers

    # Make every net's guides traversable before detailed routing reads them
    # (common.tcl pnr_bridge_wrong_way_guides; bridge-wrong-way-route-guides).
    if { $pnr_bridge_guides } {
        pnr_bridge_wrong_way_guides
    } else {
        utl::report "Guide bridging off (PNR_BRIDGE_GUIDES=0)"
    }

    utl::report "Detailed route"
    # -bottom_routing_layer/-top_routing_layer (as chip.tcl passes them)
    # are a hard error on OpenROAD 2c56926: DRT-0509/0510, "deprecated, use
    # set_routing_layers command instead". They are still listed in
    # detailed_route's define_cmd_args and still parsed into its keys array,
    # which is exactly why the 2026-09-06 API audit passed them - reading the
    # declared argument list is not enough, the proc body is the real
    # contract. The layer restriction they used to express is already applied
    # by pnr_apply_routing_layers above (set_routing_layers -signal
    # Metal2-TopMetal1 -clock Metal2-TopMetal1), so dropping them here is
    # behaviour-preserving and is what the error message itself prescribes.
    detailed_route -output_drc ${report_dir}/${proj_name}_route_drc.rpt \
                   -droute_end_iter $droute_end_iter \
                   -drc_report_iter_step 5 \
                   -clean_patches \
                   -save_guide_updates \
                   -verbose 1

    utl::report "Antenna check"
    if { [catch {check_antennas -report_file ${report_dir}/${proj_name}_antenna.rpt} antErr] } {
        utl::report "Antenna check failed (reporting only, stage unaffected): $antErr"
    }

    save_checkpoint ${proj_name}.drt
    report_image "${proj_name}.drt" true false false true
    report_design_area
} errMsg]

# The violation counts are not read here: run_pnr.sh's report_drt_outcome
# takes the router's own totals (DRT-0199) from this stage's log once it
# ends (drc-clean-pnr design D2). The route-DRC report above stays for its
# marker locations, but it is capped at 10,000 markers per violation type,
# so counting its entries understated run 38473439796 by 34x (21,110
# against the router's 715,558).

if { $err } {
    pnr_status drt failed "$errMsg"
    utl::report "ERROR in drt stage (best-effort, non-fatal to the flow): $errMsg"
    exit 1
} else {
    pnr_status drt ok "droute_end_iter=$droute_end_iter input=$drt_input"
    exit 0
}
