#!/usr/bin/env bash
# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# One Markdown paragraph on the seal + minimal DRC outcome for the P&R lane's
# run summary (change seal-and-drc-gds, spec ci-pipeline "P&R lane publishes
# the sealed GDS and the minimal DRC result").
#
#   drc_summary_line.sh <basilisk.gds.gz> <basilisk.seal.log> <sealed.gds.gz> <drc dir>

gds=$1 seal_log=$2 sealed=$3 drc_dir=$4
summary="$drc_dir/drc-summary.txt"
run_log="$drc_dir/drc-run.log"
artifact='`basilisk-pnr-drc`'

first_error() { grep -m1 -E 'ERROR|Error|Traceback' "$1" 2>/dev/null | cut -c1-200; }

echo
if [ ! -f "$gds" ]; then
    echo "**Seal + minimal DRC:** skipped - no GDS."
elif [ -f "$summary" ] && grep -q '^non-waived: ' "$summary"; then
    n=$(sed -n 's/^non-waived: //p' "$summary" | tail -1)
    unknown=$(grep -c '^waiver names an unknown rule' "$summary")
    if [ "$n" = 0 ] && [ "$unknown" = 0 ]; then
        echo "**Minimal DRC (sealed GDS):** 0 non-waived items - only the IP waiver list's rules in their macros. Report and \`drc-summary.txt\` in $artifact."
    else
        echo "**Minimal DRC (sealed GDS):** **$n non-waived items**, $unknown unknown waiver rule(s) - first entries:"
        echo
        echo '```'
        grep -E '^(not waived:|waiver names)' "$summary" | head -10
        echo '```'
        echo "Full listing in \`drc-summary.txt\` ($artifact). Best-effort: this does not fail the run."
    fi
elif [ ! -f "$sealed" ]; then
    echo "**Seal + minimal DRC:** seal failed - $(first_error "$seal_log" || true). Log in $artifact."
else
    echo "**Minimal DRC (sealed GDS):** DRC failed - $(first_error "$run_log" || true). Logs in $artifact."
fi
