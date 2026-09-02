# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Stage 2/9: pre_place - tie-fanout repair + remove_buffers, adapted from
# ../chip.tcl's "Initial Repair Netlist" section
# (openspec/changes/ci-pnr-lane/design.md D1/D2).
#
# Deliberately its own small stage: `remove_buffers` is the step known to
# segfault on roughly one run in three (docs/infra-plan.md Sec. 0). Keeping
# it alone between two checkpoints (power_grid before, pre_place after)
# means run_pnr.sh's one-retry-from-checkpoint policy replays only this
# cheap step, not the floorplan/power-grid work before it.
#
# Establishes pad-net and clock-net dont-touch plus dont_use_cells; these
# stay active (re-applied per-process) through gpl.tcl and dpl.tcl, and
# clock dont-touch is explicitly lifted again in cts.tcl - matching
# chip.tcl's own lifetime for these sets.

source [file join [file dirname [info script]] common.tcl]

set err [catch {
    pnr_load ${proj_name}.power_grid

    # Used for estimate_parasitics
    set_wire_rc -clock -layer Metal4
    set_wire_rc -signal -layer Metal4

    # Dont touch IO pads as "remove_buffers" removes them otherwise
    pnr_set_pad_dont_touch
    set clock_nets [pnr_set_clock_dont_touch]
    pnr_set_dont_use

    utl::report "Repair tie fanout"
    source scripts/repair_tie.tcl

    utl::report "Remove buffers"
    remove_buffers

    report_metrics "${proj_name}.pre_place"
    save_checkpoint ${proj_name}.pre_place
} errMsg]

if { $err } {
    pnr_status pre_place failed $errMsg
    utl::report "ERROR in pre_place stage: $errMsg"
    exit 1
} else {
    pnr_status pre_place ok
    exit 0
}
