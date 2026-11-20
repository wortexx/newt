# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Fills same-net spacing gaps in the supply grid
# (openspec/changes/snap-delay-lines-and-fill-tm1-gaps design D2). Sourced by
# power_grid_stripes.tcl after pdngen.
#
# Over each stacked SRAM column, a core_grid TopMetal2 -> Metal1 stack lands
# on a channel rail next to the macro grid's TopMetal2 -> Metal4 stack on the
# SRAM ring. Their TopMetal1 pads end 0.26-1.14 um apart on the same net,
# under the 1.64 um TM1.b spacing. pdngen fills such notches only between
# shapes of one grid, and drt does not check them.

# Every rectangle of net on layer, as {x0 y0 x1 y1 swire} in dbu: the special
# wires' boxes and each via's boxes on that layer.
proc pdn_layer_rects { net layer } {
    set lname [$layer getName]
    set rects {}
    set via_boxes [dict create]
    foreach swire [$net getSWires] {
        foreach box [$swire getWires] {
            if { ![$box isVia] } {
                if { [[$box getTechLayer] getName] eq $lname } {
                    lappend rects [list [$box xMin] [$box yMin] [$box xMax] [$box yMax] $swire]
                }
                continue
            }
            set via [$box getBlockVia]
            if { $via eq "NULL" } { set via [$box getTechVia] }
            set vname [$via getName]
            if { ![dict exists $via_boxes $vname] } {
                set boxes {}
                foreach vb [$via getBoxes] {
                    set vl [$vb getTechLayer]
                    if { $vl ne "NULL" && [$vl getName] eq $lname } {
                        lappend boxes [list [$vb xMin] [$vb yMin] [$vb xMax] [$vb yMax]]
                    }
                }
                dict set via_boxes $vname $boxes
            }
            lassign [$box getViaXY] vx vy
            foreach vb [dict get $via_boxes $vname] {
                lassign $vb x0 y0 x1 y1
                lappend rects [list [expr {$vx + $x0}] [expr {$vy + $y0}] \
                                    [expr {$vx + $x1}] [expr {$vy + $y1}] $swire]
            }
        }
    }
    return $rects
}

# Buckets rect indices by the strips of width tile that they cross along the
# axis across the gap: x strips for gaps in y (axis y), y strips for gaps in x.
proc pdn_bucket_rects { rects axis tile } {
    set lo [expr {$axis eq "y" ? 0 : 1}]
    set hi [expr {$lo + 2}]
    set buckets [dict create]
    set i 0
    foreach r $rects {
        for {set t [expr {[lindex $r $lo] / $tile}]} {$t <= [lindex $r $hi] / $tile} {incr t} {
            dict lappend buckets $t $i
        }
        incr i
    }
    return $buckets
}

# Candidate fills for gaps along axis (y: one rect above the other; x: side by
# side) as {x0 y0 x1 y1 swire}: the facing edges overlap by at least min_overlap
# and lie more than 0 and less than spacing apart.
proc pdn_gap_candidates { rects axis spacing min_overlap tile } {
    # along: the axis across the gap; across: the axis the edges overlap on.
    if { $axis eq "y" } {
        set a0 1; set a1 3; set c0 0; set c1 2
    } else {
        set a0 0; set a1 2; set c0 1; set c1 3
    }
    set seen [dict create]
    set fills {}
    dict for {t ids} [pdn_bucket_rects $rects $axis $tile] {
        set sorted [lsort -integer -index 0 [lmap i $ids { list [lindex $rects $i $a0] $i }]]
        set n [llength $sorted]
        for {set p 0} {$p < $n} {incr p} {
            set i [lindex $sorted $p 1]
            set a [lindex $rects $i]
            set aend [lindex $a $a1]
            # First rect starting beyond a's end.
            set q0 [expr {[lsearch -bisect -integer -index 0 $sorted $aend] + 1}]
            for {set q $q0} {$q < $n} {incr q} {
                set bstart [lindex $sorted $q 0]
                if { $bstart >= $aend + $spacing } { break }
                set j [lindex $sorted $q 1]
                if { [dict exists $seen "$i,$j"] } { continue }
                dict set seen "$i,$j" 1
                set b [lindex $rects $j]
                set olo [expr {max([lindex $a $c0], [lindex $b $c0])}]
                set ohi [expr {min([lindex $a $c1], [lindex $b $c1])}]
                if { $ohi - $olo < $min_overlap } { continue }
                if { $axis eq "y" } {
                    lappend fills [list $olo $aend $ohi $bstart [lindex $a 4]]
                } else {
                    lappend fills [list $aend $olo $bstart $ohi [lindex $a 4]]
                }
            }
        }
    }
    return $fills
}

# 1 if box {x0 y0 x1 y1} meets any of rects: with closed 1, touching counts;
# otherwise only an overlap with positive area does.
proc pdn_box_meets { box rects closed } {
    lassign $box x0 y0 x1 y1
    foreach r $rects {
        lassign $r rx0 ry0 rx1 ry1
        if { $closed } {
            if { $rx0 <= $x1 && $rx1 >= $x0 && $ry0 <= $y1 && $ry1 >= $y0 } { return 1 }
        } elseif { $rx0 < $x1 && $rx1 > $x0 && $ry0 < $y1 && $ry1 > $y0 } {
            return 1
        }
    }
    return 0
}

# Rects of rects within reach of box, using the x-strip buckets.
proc pdn_rects_near { box rects buckets tile } {
    lassign $box x0 y0 x1 y1
    set ids [dict create]
    for {set t [expr {$x0 / $tile}]} {$t <= $x1 / $tile} {incr t} {
        if { [dict exists $buckets $t] } {
            foreach i [dict get $buckets $t] { dict set ids $i 1 }
        }
    }
    return [lmap i [dict keys $ids] { lindex $rects $i }]
}

# Fills every gap between two shapes of the same supply net on layer_name
# whose facing edges overlap by at least the layer's minimum width and lie
# less than its spacing apart. A gap that already holds same-net metal is not
# one: that skips gaps measured from a via's inner box, and makes a second
# call add nothing. Errors, adding nothing, if a fill would touch the other
# supply net. Logs the number of fills.
proc pdn_fill_same_net_gaps { {layer_name TopMetal1} {nets {VDD VSS}} } {
    set block [ord::get_db_block]
    set layer [[ord::get_db_tech] findLayer $layer_name]
    set spacing [$layer getSpacing]
    set min_overlap [$layer getMinWidth]
    set tile [ord::microns_to_dbu 20]

    foreach name $nets {
        set rects($name) [pdn_layer_rects [$block findNet $name] $layer]
        set buckets($name) [pdn_bucket_rects $rects($name) y $tile]
    }

    set fills {}
    foreach name $nets {
        foreach axis {y x} {
            foreach cand [pdn_gap_candidates $rects($name) $axis $spacing $min_overlap $tile] {
                set box [lrange $cand 0 3]
                set near [pdn_rects_near $box $rects($name) $buckets($name) $tile]
                if { [pdn_box_meets $box $near 0] } { continue }
                foreach other $nets {
                    if { $other eq $name } { continue }
                    set onear [pdn_rects_near $box $rects($other) $buckets($other) $tile]
                    if { [pdn_box_meets $box $onear 1] } {
                        lassign $box x0 y0 x1 y1
                        error "$layer_name gap fill on $name would touch $other at\
                               x [ord::dbu_to_microns $x0]-[ord::dbu_to_microns $x1]\
                               y [ord::dbu_to_microns $y0]-[ord::dbu_to_microns $y1] um"
                    }
                }
                lappend fills $cand
            }
        }
    }

    # A gap whose sides are a pad and the via boxes inside it is found once
    # per pair of shapes ending at its edges; keep the widest fill of each.
    set kept {}
    foreach fill [lsort -integer -decreasing -index 0 [lmap f $fills {
        lassign $f x0 y0 x1 y1
        list [expr {($x1 - $x0) * ($y1 - $y0)}] $f
    }]] {
        set f [lindex $fill 1]
        if { ![pdn_box_meets [lrange $f 0 3] $kept 0] } { lappend kept $f }
    }
    set fills $kept

    # Created only after the search, so a fill is never taken for a shape.
    foreach fill $fills {
        lassign $fill x0 y0 x1 y1 swire
        set dir [expr {$x1 - $x0 >= $y1 - $y0 ? $odb::dbSBox_HORIZONTAL : $odb::dbSBox_VERTICAL}]
        odb::dbSBox_create $swire $layer $x0 $y0 $x1 $y1 "DRCFILL" $dir
    }
    utl::report "Same-net $layer_name gaps filled: [llength $fills]"
    return $fills
}
