#!/usr/bin/env bash
#
# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Prints the P&R lane summary's "Layout (GDS)" line (change stream-final-gds,
# spec ci-pipeline "P&R lane publishes the streamed GDS"). Markdown to stdout;
# the workflow appends it to $GITHUB_STEP_SUMMARY.
#
#   gds_summary.sh <final.def> <gds.gz> <stream.log>
#
# No DEF: prints nothing - the summary's "Routed design: none produced" line
# already covers it. DEF and GDS: size and empty IO instance count. DEF but
# no GDS: the stream failed (or never ran), which does not fail the run.

set -uo pipefail

def="$1" gds="$2" log="$3"

[ -f "$def" ] || exit 0

echo
if [ -s "$gds" ]; then
    io="$(sed -n 's/.*empty allowed cells: \([0-9]*\), instances: \([0-9]*\).*/\2 instances of \1 IO cells/p' "$log" 2>/dev/null | tail -1)"
    echo "**Layout (GDS):** \`$(basename "$gds")\` published ($(du -h "$gds" | cut -f1)) in \`basilisk-pnr-gds\`; ${io:-an unknown number of IO pad instances} streamed empty (pre-release IO cells, no public GDS)."
elif [ -f "$log" ]; then
    reason="$(grep -m1 'ERROR' "$log" | sed 's/^\[[^]]*\] *//')"
    echo "**Layout (GDS):** stream failed${reason:+ - $reason}. The log is in \`basilisk-pnr-gds\`; this does not fail the run."
else
    echo "**Layout (GDS):** not streamed (the stream step did not run or produced no log). This does not fail the run."
fi
