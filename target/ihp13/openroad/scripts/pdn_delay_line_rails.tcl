# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Connects the Hyperbus delay-line macros' supply rails to the core grid
# (openspec/changes/fix-delay-line-power-rails design D1, D2). Sourced by
# power_grid_stripes.tcl after pdngen.
#
# delay_line_D4_O1_6P000 takes power only on Metal1: its VDD/VSS pins are
# full-width rails at the row pitch, and its obstructions cover Metal1-Metal3,
# so no via stack can land on them. The floorplan aligns them with the core's
# follow-pin rails, but pdngen trims those rails 0.44 um short of the macro on
# both sides. Each gap gets a Metal1 box from the rail's end to the pin's edge,
# abutting the pin rather than overlapping the macro's Metal1 obstruction.

# Adds the bridges for every instance of master and logs their count. Errors
# on a non-R0 instance, or on a supply pin rail that no same-net Metal1 rail
# reaches within reach_um on either side.
proc pdn_bridge_delay_line_rails { {master delay_line_D4_O1_6P000} {reach_um 1.0} } {
    set block [ord::get_db_block]
    set m1 [[ord::get_db_tech] findLayer Metal1]
    set reach [ord::microns_to_dbu $reach_um]
    set bridges {}
    foreach inst [$block getInsts] {
        if { [[$inst getMaster] getName] ne $master } { continue }
        set name [$inst getName]
        # Pin boxes are offset by the location only; dbTransform::apply is not
        # callable from Tcl in the pinned OpenROAD, so other orientations fail.
        if { [$inst getOrient] ne "R0" } {
            error "Delay line $name is placed [$inst getOrient], only R0 is supported"
        }
        lassign [$inst getLocation] lx ly
        foreach iterm [$inst getITerms] {
            set mterm [$iterm getMTerm]
            if { [$mterm getSigType] ni {POWER GROUND} } { continue }
            set net [$iterm getNet]
            if { $net eq "NULL" || $net eq "" } {
                error "Delay line $name pin [$mterm getName] has no supply net"
            }
            foreach mpin [$mterm getMPins] {
                foreach geom [$mpin getGeometry] {
                    if { [$geom getTechLayer] eq "NULL" || [[$geom getTechLayer] getName] ne "Metal1" } { continue }
                    set px0 [expr {$lx + [$geom xMin]}]; set px1 [expr {$lx + [$geom xMax]}]
                    set py0 [expr {$ly + [$geom yMin]}]; set py1 [expr {$ly + [$geom yMax]}]
                    set found 0
                    foreach swire [$net getSWires] {
                        foreach box [$swire getWires] {
                            if { [$box isVia] || [[$box getTechLayer] getName] ne "Metal1" } { continue }
                            if { [$box yMin] != $py0 || [$box yMax] != $py1 } { continue }
                            if { [$box xMax] < $px0 && $px0 - [$box xMax] <= $reach } {
                                lappend bridges [list $swire [$box xMax] $py0 $px0 $py1]
                                incr found
                            } elseif { [$box xMin] > $px1 && [$box xMin] - $px1 <= $reach } {
                                lappend bridges [list $swire $px1 $py0 [$box xMin] $py1]
                                incr found
                            }
                        }
                    }
                    if { !$found } {
                        error "Delay line $name [$net getName] rail at y\
                               [ord::dbu_to_microns $py0]-[ord::dbu_to_microns $py1] um:\
                               no [$net getName] Metal1 rail within $reach_um um on either side"
                    }
                }
            }
        }
    }
    # Created only after the search, so a bridge is never taken for a rail.
    # The direction only sets how write_def writes the square box: as a
    # horizontal path along the rail, like the rails themselves, instead of an
    # equivalent vertical one. The geometry is the same either way.
    foreach bridge $bridges {
        lassign $bridge swire x0 y0 x1 y1
        odb::dbSBox_create $swire $m1 $x0 $y0 $x1 $y1 "FOLLOWPIN" $odb::dbSBox_HORIZONTAL
    }
    utl::report "Delay-line rail bridges: [llength $bridges]"
}
