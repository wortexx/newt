# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Tobias Senti <tsenti@ethz.ch>
# - Jannis Schönleber <janniss@iis.ee.ethz.ch>
# - Philippe Sauter <phsauter@ethz.ch>

# Some useful functions for floorplaning

#Add Placement blockage
proc add_macro_blockage {negative_padding name1 name2} {
  set block [ord::get_db_block]
  set inst1 [odb::dbBlock_findInst $block $name1]
  set inst2 [odb::dbBlock_findInst $block $name2]
  set bb1 [odb::dbInst_getBBox $inst1]
  set bb2 [odb::dbInst_getBBox $inst2]
  # Find min max of X and Y
  set minx [expr min( [odb::dbBox_xMin $bb1], [odb::dbBox_xMin $bb2]) + [ord::microns_to_dbu $negative_padding]]
  set miny [expr min( [odb::dbBox_yMin $bb1], [odb::dbBox_yMin $bb2]) + [ord::microns_to_dbu $negative_padding]]
  set maxx [expr max( [odb::dbBox_xMax $bb1], [odb::dbBox_xMax $bb2]) - [ord::microns_to_dbu $negative_padding]]
  set maxy [expr max( [odb::dbBox_yMax $bb1], [odb::dbBox_yMax $bb2]) - [ord::microns_to_dbu $negative_padding]]

  set blockage [odb::dbBlockage_create [ord::get_db_block] $minx $miny $maxx $maxy]
  return $blockage
}

proc create_vert_stripe_blockage {firstX lastX pitchX spacingX width minY maxY} {
  set firstX_dbu [ord::microns_to_dbu $firstX]
  set minY_dbu   [ord::microns_to_dbu $minY]
  set lastX_dbu  [ord::microns_to_dbu $lastX]
  set maxY_dbu   [ord::microns_to_dbu $maxY]
  set pitchx_dbu [ord::microns_to_dbu $pitchX]
  set spacingX_dbu  [ord::microns_to_dbu $spacingX]
  set width_dbu  [ord::microns_to_dbu $width]
  set block      [ord::get_db_block]

  for {set x $firstX_dbu} {$x <= $lastX_dbu} {set x [expr $x + $pitchx_dbu]} {
    set x0 [expr $x - $width_dbu/2]
    set x1 [expr $x + $width_dbu/2]
    puts "stripe blockage: x0:$x0, x1:$x1"
    set blockage [odb::dbBlockage_create $block $x0 $minY_dbu $x1 $maxY_dbu]
    set x0 [expr $x1 + $spacingX_dbu]
    set x1 [expr $x0 + $width_dbu]
    puts "stripe blockage2: x0:$x0, x1:$x1"
    set blockage [odb::dbBlockage_create $block $x0 $minY_dbu $x1 $maxY_dbu]
    
    set $blockage setSoft
  }
}

# place_macro only allows R0, R180, MX, MY -> doesn't work for us
proc placeInstance { name x y orient } {
  puts "placing $name at {$x $y} $orient"

  set block [ord::get_db_block]
  set inst [$block findInst $name]
  if {$inst == "NULL"} {
    error "Cannot find instance $name"
  }

  $inst setLocationOrient $orient
  $inst setLocation [ord::microns_to_dbu $x] [ord::microns_to_dbu $y]
  $inst setPlacementStatus FIRM
}


# Block placement in the gap between each macro and the core edge.
# The floorplans keep macros floorPaddingX/Y off the core edge without cutting
# the rows there, so the placer filled those margins with logic that the macro
# walls in: SRAMs obstruct Metal1-Metal4, so its nets crossed the macro on
# almost nothing or left the core (run 38094932339: 6,308 such cells, 9,313
# nets routed outside the core; docs/infra-plan.md Phase 11). For every BLOCK
# instance, each side whose distance to the matching core edge is in
# (0, max_gap] microns gets a hard placement blockage over that gap, along the
# side's full length. Call it after the last macro is placed. max_gap 0 turns
# it off (openspec/changes/keep-cells-out-of-macro-margins design D1).
proc block_macro_core_margins {max_gap} {
  if { $max_gap <= 0 } {
    puts "Macro margin blocking: off"
    return 0
  }
  set block   [ord::get_db_block]
  set core    [$block getCoreArea]
  set cx0     [$core xMin]
  set cy0     [$core yMin]
  set cx1     [$core xMax]
  set cy1     [$core yMax]
  set gap_dbu [ord::microns_to_dbu $max_gap]
  set count   0

  foreach inst [$block getInsts] {
    if { [[$inst getMaster] getType] ne "BLOCK" } { continue }
    set bbox [$inst getBBox]
    set x0 [$bbox xMin]
    set y0 [$bbox yMin]
    set x1 [$bbox xMax]
    set y1 [$bbox yMax]
    # side -> gap and the blockage box covering it
    set sides [list \
      W [expr {$x0 - $cx0}] [list $cx0 $y0 $x0  $y1] \
      E [expr {$cx1 - $x1}] [list $x1  $y0 $cx1 $y1] \
      S [expr {$y0 - $cy0}] [list $x0  $cy0 $x1 $y0] \
      N [expr {$cy1 - $y1}] [list $x0  $y1 $x1  $cy1]]
    foreach {side gap box} $sides {
      if { $gap <= 0 || $gap > $gap_dbu } { continue }
      odb::dbBlockage_create $block {*}$box
      incr count
      puts [format "Macro margin blocked: %s %s, gap %.2f um" \
              [$inst getName] $side [ord::dbu_to_microns $gap]]
    }
  }
  puts "Macro margin blocking: $count blockages (gap <= $max_gap um)"
  return $count
}

proc addHaloToBlock {left bottom right top name} {
  set block [ord::get_db_block]
  set inst [odb::dbBlock_findInst $block $name]

  set bbox [odb::dbInst_getBBox $inst]
  set minx [odb::dbBox_xMin $bbox]
  set miny [odb::dbBox_yMin $bbox]
  set maxx [odb::dbBox_xMax $bbox]
  set maxy [odb::dbBox_yMax $bbox]

  set minx [expr $minx - [ord::microns_to_dbu $left]]
  set miny [expr $miny - [ord::microns_to_dbu $bottom]]
  set maxx [expr $maxx + [ord::microns_to_dbu $right]]
  set maxy [expr $maxy + [ord::microns_to_dbu $top]]
}
