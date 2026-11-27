#!/usr/bin/env bash
# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Minimal DRC of the sealed GDS with IHP's run_drc.py, then the IP waiver
# summary (change seal-and-drc-gds, design D3/D4).
#
#   drc.sh <tech_dir> <sealed.gds.gz> <top cell> <run dir> <jobs> <waivers.yaml>
#
# Writes <run dir>/: the runner's .lyrdb and logs, drc-run.log, drc-summary.txt.
# The exit status is the summary's: 0 when every item is waived, 1 when not,
# 2 on bad input. run_drc.py's own status is not used - it is 1 for any item at
# all, waived or not.

set -uo pipefail

tech_dir=$1 gds=$2 top=$3 run_dir=$4 jobs=$5 waivers=$6
scripts=$(cd "$(dirname "$0")" && pwd)
runner="$tech_dir/tech/drc/run_drc.py"

for f in "$gds" "$runner" "$waivers"; do
    [[ -f "$f" ]] || { echo "ERROR: not found: $f" >&2; exit 2; }
done
# run_drc.py builds a shell command line from these (as croc's run_drc.sh notes).
for v in "$gds" "$top" "$run_dir"; do
    [[ "$v" =~ ^[A-Za-z0-9_./:@%+,=-]+$ ]] || { echo "ERROR: unsupported characters in: $v" >&2; exit 2; }
done

rm -rf "${run_dir:?}"
mkdir -p "$run_dir"
log="$run_dir/drc-run.log"

# --minimum_drc implies no extra rules, no offgrid/angle checks and no antenna.
# FEOL stays on (unlike croc's --minimal): it caught the flow's own delay-line
# grid bug (#104), and the IP waivers are FEOL rules.
echo "run_drc.py --minimum_drc --no_density --run_mode=deep --mp=$jobs on $gds ($top)"
SECONDS=0
python3 "$runner" --path="$gds" --topcell="$top" --run_dir="$run_dir" \
    --minimum_drc --no_density --run_mode=deep --mp="$jobs" > "$log" 2>&1
runner_rc=$?
echo "run_drc.py exit $runner_rc after ${SECONDS}s (1 means items were found; the summary decides)"

# A parallel worker that crashes is only logged, and the merged report then
# silently lacks its rules.
if grep -Fq " generated an exception:" "$log"; then
    echo "ERROR: a parallel DRC worker failed; see $log" >&2
    grep -F -A3 " generated an exception:" "$log" >&2
    exit 2
fi
shopt -s nullglob
reports=("$run_dir"/*.lyrdb)
if [[ ${#reports[@]} -ne 1 ]]; then
    echo "ERROR: expected one .lyrdb in $run_dir, found ${#reports[@]}; see $log" >&2
    tail -20 "$log" >&2
    exit 2
fi

python3 "$scripts/drc_summary.py" --gds "$gds" --waivers "$waivers" \
    --out "$run_dir/drc-summary.txt" "${reports[0]}"
