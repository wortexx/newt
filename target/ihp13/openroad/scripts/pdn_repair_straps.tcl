# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# pdngen's channel-repair straps: count them, and remove them behind a
# connectivity gate (openspec/changes/clear-sram-corner-router-shorts
# design D1-D3). Sourced by power_grid_stripes.tcl after pdngen.
#
# pdngen always repairs channels (OpenROAD 2c56926971: repairGridChannels
# runs unconditionally, pdn::allow_repair_channels only turns an unrepaired
# channel into an error). Each repair is a TopMetal2 strap shorter than the
# core with a full via stack to every Metal1 rail under it; the core stripes
# span the core, so "shorter than the core" selects exactly the repairs.

# {net box} for every TopMetal2 supply strap shorter than the core height
# minus 1 um.
proc pdn_repair_straps {} {
    set block [ord::get_db_block]
    set core [$block getCoreArea]
    set limit [expr {[$core yMax] - [$core yMin] - [ord::microns_to_dbu 1.0]}]
    set straps {}
    foreach net {VDD VSS} {
        foreach swire [[$block findNet $net] getSWires] {
            foreach box [$swire getWires] {
                if { [$box isVia] || [[$box getTechLayer] getName] ne "TopMetal2" } { continue }
                set h [expr {[$box yMax] - [$box yMin]}]
                if { $h > [expr {[$box xMax] - [$box xMin]}] && $h < $limit } {
                    lappend straps [list $net $box]
                }
            }
        }
    }
    return $straps
}

proc pdn_report_repair_straps {} {
    utl::report "PDN TopMetal2 straps shorter than the core: [llength [pdn_repair_straps]]"
}

# Removes every repair strap, each via of its net whose centre lies inside
# it, and each other wire of its net wholly inside it (the stack's pads).
# Containment, not the centre, selects wires: a Metal1 rail crossing the
# strap can have its centre inside it and must stay.
proc pdn_remove_repair_straps {} {
    set block [ord::get_db_block]
    set straps [pdn_repair_straps]
    set removed 0
    foreach strap $straps {
        lassign $strap net sbox
        set x0 [$sbox xMin]; set x1 [$sbox xMax]
        set y0 [$sbox yMin]; set y1 [$sbox yMax]
        set under {}
        foreach swire [[$block findNet $net] getSWires] {
            foreach box [$swire getWires] {
                if { $box eq $sbox } { continue }
                if { [$box isVia] } {
                    set cx [expr {([$box xMin] + [$box xMax]) / 2}]
                    set cy [expr {([$box yMin] + [$box yMax]) / 2}]
                    set hit [expr {$cx >= $x0 && $cx <= $x1 && $cy >= $y0 && $cy <= $y1}]
                } else {
                    set hit [expr {[$box xMin] >= $x0 && [$box xMax] <= $x1 &&
                                   [$box yMin] >= $y0 && [$box yMax] <= $y1}]
                }
                if { $hit } { lappend under $box }
            }
        }
        foreach box $under { odb::dbSBox_destroy $box }
        odb::dbSBox_destroy $sbox
        incr removed [llength $under]
    }
    utl::report "PDN channel-repair straps removed: [llength $straps] ($removed shapes under them)"
}

# check_power_grid's reports for one net, one entry per violation (type,
# sources and bbox joined), written to <report_dir>/<proj>_pgcheck_<net>_<tag>.rpt.
# The check raises PSM-0069 whenever it reports anything, so only that
# error is expected; any other error, or PSM-0069 without a report file,
# fails the caller.
proc pdn_check_net { net tag } {
    global report_dir proj_name
    set rpt ${report_dir}/${proj_name}_pgcheck_${net}_${tag}.rpt
    file delete $rpt
    if { [catch {check_power_grid -net $net -dont_require_terminals -error_file $rpt} err] } {
        if { ![string match "*PSM-0069*" $err] || ![file exists $rpt] } {
            error "Power grid check $net ($tag) failed to run: $err"
        }
    }
    set entries {}
    if { [file exists $rpt] } {
        set fh [open $rpt r]
        set entry {}
        foreach line [split [read $fh] "\n"] {
            set line [string trim $line]
            if { [string match "violation type:*" $line] } {
                if { $entry ne {} } { lappend entries [join $entry " | "] }
                set entry [list $line]
            } elseif { $line ne {} && $entry ne {} } {
                lappend entry $line
            }
        }
        if { $entry ne {} } { lappend entries [join $entry " | "] }
        close $fh
    }
    return $entries
}

# Checks VDD and VSS, removes the repair straps, checks again, and errors if
# the second check reports anything the first did not. Reports present before
# the removal (today's grid has 14 per net, docs/infra-plan.md) do not fail it.
proc pdn_remove_repair_straps_checked {} {
    foreach net {VDD VSS} { set before($net) [pdn_check_net $net before] }
    pdn_remove_repair_straps
    set failed {}
    foreach net {VDD VSS} {
        set new {}
        foreach entry [pdn_check_net $net after] {
            if { $entry ni $before($net) } { lappend new $entry }
        }
        if { $new eq {} } {
            utl::report "Power grid check $net: ok ([llength $before($net)] pre-existing)"
        } else {
            utl::report "Power grid check $net: failed ([llength $new] new)"
            foreach entry $new { utl::report "  $entry" }
            lappend failed $net
        }
    }
    if { $failed ne {} } {
        error "Removing the channel-repair straps disconnected supply shapes on: $failed"
    }
}

# Every run's final check (openspec/changes/fix-delay-line-power-rails D3):
# errors if either supply net reports any unconnected shape or instance.
proc pdn_check_grid {} {
    set failed {}
    foreach net {VDD VSS} {
        set entries [pdn_check_net $net final]
        if { $entries eq {} } {
            utl::report "Power grid check $net: clean"
        } else {
            utl::report "Power grid check $net: failed ([llength $entries] reports)"
            foreach entry $entries { utl::report "  $entry" }
            lappend failed $net
        }
    }
    if { $failed ne {} } {
        error "Unconnected supply shapes on: $failed"
    }
}
