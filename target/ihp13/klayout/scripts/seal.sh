#!/usr/bin/env bash
# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Seal the streamed GDS (change seal-and-drc-gds, design D2): read the die area
# from the DEF, generate IHP's seal ring of die + 2 x margin, and wrap chip and
# ring in <design>_sealed.
#
#   seal.sh <klayout> <tech_dir> <def> <chip.gds.gz> <design> <margin_um> \
#           <ring.gds.gz> <sealed.gds.gz>

set -euo pipefail

klayout=$1 tech_dir=$2 def=$3 chip=$4 design=$5 margin=$6 ring=$7 out=$8
scripts=$(cd "$(dirname "$0")" && pwd)

for f in "$chip" "$def"; do
    [[ -f "$f" ]] || { echo "ERROR: not found: $f" >&2; exit 1; }
done

# DEF header: "UNITS DISTANCE MICRONS 1000 ;" and
# "DIEAREA ( x0 y0 ) ( x1 y1 ) ;" (a rectangle; a polygon die is not handled).
units=$(grep -m1 '^UNITS DISTANCE MICRONS' "$def" | awk '{print $4}')
read -r x0 y0 x1 y1 < <(grep -m1 '^DIEAREA' "$def" |
    awk 'NF == 10 && $2 == "(" && $5 == ")" && $6 == "(" && $9 == ")" {print $3, $4, $7, $8}') || true
if [[ -z "$units" || -z "${y1:-}" ]]; then
    echo "ERROR: no UNITS / rectangular DIEAREA in the header of $def" >&2
    exit 1
fi
read -r die_w die_h ring_w ring_h dx dy < <(awk -v u="$units" -v m="$margin" \
    -v x0="$x0" -v y0="$y0" -v x1="$x1" -v y1="$y1" 'BEGIN {
        w = (x1 - x0) / u; h = (y1 - y0) / u
        printf "%.3f %.3f %.3f %.3f %.3f %.3f\n", w, h, w + 2*m, h + 2*m, m - x0/u, m - y0/u }')
echo "die ${die_w} x ${die_h} um (origin ${x0} ${y0} dbu), margin ${margin} um -> ring ${ring_w} x ${ring_h} um"

# The ring's PCell labels it with its PDK commit via `git rev-parse` in the
# tech checkout; mark that checkout safe for when its owner differs (a container).
tech_root=$(cd "$tech_dir/../../.." && pwd)   # .../klayout-tech (ihp-sg13g2/libs.tech/klayout)
n=${GIT_CONFIG_COUNT:-0}   # append: the P&R lane sets entries of its own
export "GIT_CONFIG_KEY_$n=safe.directory" "GIT_CONFIG_VALUE_$n=$tech_root"
export GIT_CONFIG_COUNT=$((n + 1))

"$klayout" -b -rd tech_dir="$tech_dir" -rd width="$ring_w" -rd height="$ring_h" \
    -rd output="$ring" -r "$scripts/seal_ring.py"
"$klayout" -b -rd chip_gds="$chip" -rd seal_gds="$ring" -rd design_name="$design" \
    -rd dx="$dx" -rd dy="$dy" -rd out_file="$out" -r "$scripts/merge_seal.py"
