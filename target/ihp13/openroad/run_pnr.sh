#!/usr/bin/env bash
#
# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Driver for the staged, unattended P&R flow (docs/infra-plan.md Phase 5;
# openspec/changes/ci-pnr-lane/design.md D1). Sequences the per-stage
# OpenROAD scripts in scripts/pnr/, each run as its own `openroad -exit`
# process so a segfault (remove_buffers' known ~1-in-3 failure mode) kills
# only that stage, not the whole run, and so a stopped/killed run can
# resume from the last completed checkpoint instead of restarting.
#
# Invoked via `make run-pnr` (openroad.mk), which sets the same
# NETLIST/TOP_DESIGN/PROJ_NAME/SAVE/REPORTS/PDK env vars run-openroad uses,
# from cwd target/ihp13/openroad (required - the stage scripts source
# `scripts/...` and `src/...` relative to that directory, matching
# chip.tcl's own convention).
#
# Env vars this driver reads (all optional):
#   PNR_GATE               Last stage that must succeed for a 0 exit.
#                           Default: grt (specs/pnr-flow: "gated through
#                           global route"). Must name a stage below.
#   PNR_SKIP_GRT_REPAIR    Passed through to grt_repair.tcl (design D2).
#   PNR_DRT_END_ITER       Passed through to drt.tcl's -droute_end_iter.
#                           Empty or unset: drt.tcl's 40; the P&R lane
#                           passes 28.
#   PNR_SKIP_ANTENNA_REPAIR Passed through to drt.tcl: "1" skips
#                           repair_antennas (the P&R lane's
#                           antenna_repair=skip). Unset: repair runs.
#   PNR_ANTENNA_REPAIR_MODE Passed through to drt.tcl when repair runs:
#                           `jumper` (repair_antennas -jumper_only) or
#                           `full` (jumpers and diodes; hung in runs
#                           34389061373 and 39696194006). Empty or unset:
#                           jumper. Anything else fails drt before it loads.
#   PNR_STAGE_TIMEOUT      Per-stage wall-clock timeout in seconds for any
#                           stage without its own override below.
#                           Default: 21600 (6h).
#   PNR_TIMEOUT_<STAGE>    Per-stage override, e.g. PNR_TIMEOUT_DRT=57600.
#   PNR_STOP_AFTER         Stop once this stage completes, instead of
#                           continuing through `final`. Must name a stage
#                           below. Lets a run exercise one part of the flow
#                           without paying for the rest (design D1: "a human
#                           can rerun exactly one stage"); combined with
#                           restored checkpoints it makes targeted tests
#                           cheap. Does not change the gate: a stop before
#                           PNR_GATE still exits non-zero, since the gate
#                           was never reached.
#   PNR_GPL_DENSITY        Passed through to gpl.tcl: the global-placement
#                           starting target density for both passes. Empty or
#                           unset: pnr_gpl_density's default in
#                           scripts/pnr/common.tcl (0.50; 0.65 before
#                           adopt-drc-clean-defaults-and-requote).
#   PNR_GPL_KEEP_RESIZE    Passed through to gpl.tcl: pass 2's
#                           -keep_resize_below_overflow. Empty or unset:
#                           pnr_gpl_keep_resize's default in common.tcl (0,
#                           virtual timing-driven repair); 1.0 is OpenROAD's
#                           default.
#   PNR_DIE_SCALE          Passed through to the floorplan: the core's width
#                           and height relative to the taped-out die. Empty or
#                           unset: pnr_die_scale's default in common.tcl
#                           (1.25); 1.10 (a 6777 x 5950 um die) was the
#                           default before adopt-drc-clean-defaults-and-
#                           requote; 1.0 is the taped-out 6230 x 5478 um
#                           die.
#   PNR_MACRO_MARGIN_MAX   Passed through to the floorplan: the widest gap
#                           between a macro and the core edge, in microns,
#                           that is blocked for placement. Empty or unset:
#                           pnr_macro_margin_max's default in common.tcl (20,
#                           covering every margin of the current floorplan);
#                           0 turns the blocking off. Changing it invalidates
#                           every checkpoint from floorplan on.
#   PNR_DPL_LEGALIZER      Passed through to every detailed_placement call
#                           (dpl, cts, grt_repair): `diamond` or
#                           `negotiation`. Empty or unset: pnr_dpl_legalizer's
#                           default in common.tcl (diamond). Either way dpl
#                           and cts end with a gated legality check.
#   PNR_DPL_MAX_DISPLACEMENT Passed through to every detailed_placement
#                           call as -max_displacement, in microns: one value
#                           or "x y". Empty or unset: pnr_dpl_max_displacement's
#                           default in common.tcl (1000 1000); "openroad"
#                           keeps OpenROAD's own window.
#   PNR_GRT_METAL2_ADJUST  Passed through to every routing stage (grt,
#                           grt_repair, drt): the share of Metal2's capacity
#                           global routing holds back, in [0, 1). Empty or
#                           unset: pnr_grt_metal2_adjust's default in
#                           common.tcl (0.60; 0.30 before adopt-drc-clean-
#                           defaults-and-requote); Metal3 stays at 0.30.
#   PNR_GRT_SRAM_METAL5_ADJUST Passed through to every routing stage (grt,
#                           grt_repair, drt): the share of Metal5's capacity
#                           global routing holds back inside every SRAM's
#                           footprint, in [0, 1). Empty or unset:
#                           pnr_grt_sram_metal5_adjust's default in
#                           common.tcl (0.55; 0, no hold-back, before
#                           adopt-drc-clean-defaults-and-requote).
#   PNR_CELL_PAD_SITES     Passed through to gpl and every legalization
#                           (dpl, cts, grt_repair): free sites kept on each
#                           side of every standard cell. Empty or unset:
#                           pnr_cell_pad_sites's default in common.tcl (0,
#                           no padding). final clears it before fillers.
#   PNR_BRIDGE_GUIDES      Passed through to drt.tcl: "0" skips copying
#                           wrong-direction route guides onto the adjacent
#                           preferred-direction layer before detailed routing
#                           (DRT-0218 otherwise). Empty or unset: on.
#   PNR_DRY_RUN            If "1", print the planned per-stage commands
#                           (in order, honoring resume-skip) and exit 0
#                           without invoking OpenROAD at all - the cheap
#                           validation path (tasks.md 2.3) for CI/review.
#
# Resuming a checkpoint made before adopt-drc-clean-defaults-and-requote:
# the defaults above moved (die 1.10 -> 1.25, density 0.65 -> 0.50, Metal2
# 0.30 -> 0.60, SRAM Metal5 0 -> 0.55, antenna repair skipped -> jumper,
# lane budget 5 -> 28), and nothing in a checkpoint records the values it
# was built with. Set the old values explicitly (PNR_DIE_SCALE=1.10
# PNR_GPL_DENSITY=0.65 PNR_GRT_METAL2_ADJUST=0.30
# PNR_GRT_SRAM_METAL5_ADJUST=0 PNR_SKIP_ANTENNA_REPAIR=1, and
# PNR_DRT_END_ITER=5 for the lane's old budget), or the resumed stages mix
# settings with the restored ones.
#
# Exit status: 0 iff every stage up to and including PNR_GATE completed
# (skipped-via-resume counts as completed). Non-zero otherwise. Stages
# after the gate (grt_repair/drt/final by default) never affect this -
# their outcome is only recorded in the status log.

set -uo pipefail

: "${PROJ_NAME:?PROJ_NAME must be set}"
: "${SAVE:?SAVE must be set}"
: "${REPORTS:?REPORTS must be set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PNR_SCRIPTS_DIR="${SCRIPT_DIR}/scripts/pnr"
STATUS_LOG="${SAVE}/pnr_status.log"

mkdir -p "${SAVE}" "${REPORTS}"

# Ordered stage list, each stage's completion-marker checkpoint name (what
# save_checkpoint in that stage's .tcl file ultimately produces - see each
# script's header comment), and its retry budget.
STAGES=(floorplan pre_place gpl dpl cts grt grt_repair drt final)
declare -A STAGE_CHECKPOINT=(
    [floorplan]=power_grid
    [pre_place]=pre_place
    [gpl]=gpl2
    [dpl]=dpl
    [cts]=cts
    [grt]=grt
    [grt_repair]=grt_repaired
    [drt]=drt
    [final]=final
)
# Only pre_place is known to segfault intermittently (remove_buffers,
# docs/infra-plan.md Sec. 0); everything else defaults to no retry.
declare -A STAGE_RETRIES=(
    [floorplan]=0 [pre_place]=1 [gpl]=0 [dpl]=0 [cts]=0
    [grt]=0 [grt_repair]=0 [drt]=0 [final]=0
)
declare -A STAGE_TIMEOUT_DEFAULT=(
    [floorplan]=3600 [pre_place]=1800 [gpl]=14400 [dpl]=14400 [cts]=28800
    [grt]=14400 [grt_repair]=21600 [drt]=57600 [final]=3600
)

STOP_AFTER="${PNR_STOP_AFTER:-}"
if [ -n "$STOP_AFTER" ]; then
    stop_valid=0
    for s in "${STAGES[@]}"; do
        [ "$s" = "$STOP_AFTER" ] && stop_valid=1
    done
    if [ "$stop_valid" -ne 1 ]; then
        echo "::error::PNR_STOP_AFTER=${STOP_AFTER} is not a known stage (${STAGES[*]})" >&2
        exit 2
    fi
fi

GATE="${PNR_GATE:-grt}"
gate_valid=0
for s in "${STAGES[@]}"; do
    [ "$s" = "$GATE" ] && gate_valid=1
done
if [ "$gate_valid" -ne 1 ]; then
    echo "::error::PNR_GATE=${GATE} is not a known stage (${STAGES[*]})" >&2
    exit 2
fi

# True when PNR_STOP_AFTER names this stage. Checked on every path that
# finishes a stage - ran it, skipped it via resume, or listed it in a dry
# run - so the stop point is the same regardless of how the stage was
# satisfied.
stop_here() {
    [ -n "$STOP_AFTER" ] && [ "$1" = "$STOP_AFTER" ]
}

log_status() {
    # $1=stage $2=status $3=detail(optional)
    printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "${STATUS_LOG}"
}

checkpoint_zip() {
    echo "${SAVE}/${PROJ_NAME}.${STAGE_CHECKPOINT[$1]}.zip"
}

stage_timeout() {
    local stage="$1" override_var
    override_var="PNR_TIMEOUT_$(echo "$stage" | tr '[:lower:]' '[:upper:]')"
    if [ -n "${!override_var:-}" ]; then
        echo "${!override_var}"
    else
        echo "${PNR_STAGE_TIMEOUT:-${STAGE_TIMEOUT_DEFAULT[$stage]}}"
    fi
}

run_stage_once() {
    local stage="$1" logfile="${REPORTS}/pnr_${1}.log" timeout_s
    timeout_s="$(stage_timeout "$stage")"
    echo "::group::pnr stage ${stage} (timeout ${timeout_s}s)"
    # openroad's own -log already writes this stage's complete output to
    # ${logfile} for the artifact upload; the gawk pipe below adds wall-
    # clock timestamps on top of that (useful for per-iteration timing
    # diagnosis - see grt.tcl's own comment history) but its output goes
    # to ${logfile}.timestamped now, NOT to this script's stdout.
    #
    # It used to go to stdout, which the CI workflow streams live into
    # the GitHub Actions job log. task 2.4 bring-up (pnr-bringup-5, run
    # 34127033481) hit a real self-hosted-runner failure from that: -verbose
    # global_route in grt.tcl dumped ~5,472 individual net names in under
    # 50ms, the runner's live log-streaming channel choked on the burst,
    # and GitHub declared "the self-hosted runner lost communication with
    # the server" ~10h later - even though the underlying openroad process
    # kept running fine on the VM and grt itself succeeded in the meantime
    # (confirmed only by reading ${logfile} directly off the VM's disk,
    # never via anything GitHub received). Every progress check this whole
    # bring-up effort has done went through reading these -log files
    # directly (az vm run-command), never the Actions UI's live tail - so
    # dropping the stdout mirror costs no monitoring capability and removes
    # the failure mode outright, without touching any OpenROAD-side
    # behavior (-verbose stays; still fully diagnosable via the
    # .timestamped file, which "Upload reports and logs" already picks up).
    QT_QPA_PLATFORM=offscreen timeout "${timeout_s}" openroad -exit \
        "${PNR_SCRIPTS_DIR}/${stage}.tcl" -log "${logfile}" \
        2>&1 | TZ=UTC gawk '{ print strftime("[%Y-%m-%d %H:%M %Z]"), $0 }' \
        >> "${logfile}.timestamped"
    local rc=${PIPESTATUS[0]}
    echo "::endgroup::"
    return "$rc"
}

# Post-dpl placement report (specs/pnr-flow "The run reports how global
# placement ended"; raise-gpl-density-target design D2,
# use-diamond-legalizer design D5). One line with what decides dpl's
# legalization: whether gpl's last pass reverted after a divergence
# (GPL-0999) and at what overflow, the final placement area inflation
# (GPL-1014), dpl's utilization (DPL-0009), the legalizer that ran (the
# `Legalizer:` line pnr_detailed_placement logs), dpl's legality check
# (its own pnr_status.log line) and, for the negotiation legalizer, the
# illegal cells it starts from (its iteration-0 row; the diamond legalizer
# logs no such count). dpl prints utilization, legalizer and iteration-0
# row before it legalizes, so they are there even if the stage later times
# out. Warns when gpl reverted on divergence, the state that left 80-220 k
# illegal cells in the runs on record (docs/infra-plan.md Phase 11). Never
# changes the exit status.
report_placement_state() {
    local gpl="${REPORTS}/pnr_gpl.log" dpl="${REPORTS}/pnr_dpl.log"
    local revert area util illegal legalizer dpl_status legality
    revert="$(sed -n 's/.*GPL-0999\] Revert to iter: *\([0-9]*\) overflow: *\([0-9.]*\).*/iter \1, overflow \2/p' \
        "$gpl" 2>/dev/null | tail -1)"
    area="$(sed -n 's/.*GPL-1014\] Final placement area: .*(\([-+0-9.]*%\)).*/\1/p' \
        "$gpl" 2>/dev/null | tail -1)"
    util="$(sed -n 's/.*DPL-0009\] Utilization: *\([0-9.]*%\).*/\1/p' "$dpl" 2>/dev/null | head -1)"
    illegal="$(awk -F'|' '/^ *0 \|/ { gsub(/ /, "", $3); print $3; exit }' "$dpl" 2>/dev/null)"
    legalizer="$(sed -n 's/.*Legalizer: *\([a-z]*\).*/\1/p' "$dpl" 2>/dev/null | head -1)"
    if [ -z "$illegal" ] && [ "$legalizer" = "diamond" ]; then
        illegal="not logged by the diamond legalizer"
    fi
    # dpl.tcl's own status line comes first; the driver's "failed exit=..."
    # line, if any, is appended only after this report.
    dpl_status="$(grep -m1 '^dpl ' "$STATUS_LOG" 2>/dev/null)"
    local detail="${dpl_status#dpl failed }"
    if [ -z "$legalizer" ]; then
        legality="no legality check (dpl log predates it)"
    elif [ -z "$dpl_status" ]; then
        legality="no legality check result (dpl did not finish)"
    elif [ "${dpl_status#dpl ok}" != "$dpl_status" ]; then
        legality="legality check passed"
    elif [ "${detail#illegal placement after dpl: }" != "$detail" ]; then
        legality="legality check FAILED (${detail#illegal placement after dpl: })"
    else
        legality="dpl failed before its legality check (${detail})"
    fi
    # Cells walled in by macros (pnr_report_macro_margins in dpl.tcl;
    # keep-cells-out-of-macro-margins design D3). The margins should be empty.
    local margins channels margin_cells
    margins="$(sed -n 's/.*Macro margins: *//p' "$dpl" 2>/dev/null | head -1)"
    channels="$(sed -n 's/.*Macro channels: *//p' "$dpl" 2>/dev/null | head -1)"
    margin_cells="${margins%% cells*}"
    if [[ "$margin_cells" =~ ^[0-9]+$ ]] && [ "$margin_cells" -gt 0 ]; then
        echo "::warning::Cells placed in macro margins: ${margins}; macros wall them in, so their nets cross the macro or leave the core. See docs/infra-plan.md Phase 11 (PNR_MACRO_MARGIN_MAX)."
    fi
    local macro_fields="macro margins: ${margins:-not reported}, macro channels: ${channels:-not reported}"
    if [ ! -f "$gpl" ]; then
        # gpl came from a restored checkpoint: no gpl figures, but dpl's own
        # fields still matter (use-diamond-legalizer task 8.3).
        echo "Placement: gpl fields not reported (no ${gpl}; gpl restored from a checkpoint?); dpl utilization ${util:-?} (DPL-0009), legalizer ${legalizer:-unknown}, ${legality}, illegal cells at legalizer iteration 0: ${illegal:-none reported}, ${macro_fields}."
        return 0
    fi
    local msg="gpl final area ${area:-?}, dpl utilization ${util:-?} (DPL-0009), legalizer ${legalizer:-unknown}, ${legality}, illegal cells at legalizer iteration 0: ${illegal:-none reported}, ${macro_fields}"
    # Only a revert in the last gpl pass matters to dpl: GPL-0999 after the
    # pass-2 marker.
    local last_revert
    last_revert="$(sed -n '/Global Placement (2)/,$p' "$gpl" 2>/dev/null | grep -c 'GPL-0999')"
    if [ "${last_revert:-0}" -gt 0 ]; then
        echo "::warning::Global placement pass 2 reverted after a divergence (${revert}); dpl inherits an unconverged placement: ${msg}. See docs/infra-plan.md Phase 11 (PNR_GPL_KEEP_RESIZE)."
    else
        echo "Placement: gpl pass 2 converged without a revert; ${msg}."
    fi
}

# Count the nets that global routing routed outside the core, from grt's
# route guides (keep-cells-out-of-macro-margins design D4). Cells walled in
# behind macros escape through the band between the core and the pads, which
# has almost no capacity: 9,313 such nets in run 38094932339
# (docs/infra-plan.md Phase 11). A net counts once, if any of its guide
# rectangles has its centre outside the core. Only reads what this grt run
# logged, so a stale guide file is never counted. Never changes the exit
# status.
report_routes_outside_core() {
    local log="${REPORTS}/pnr_grt.log" core guide n
    core="$(sed -n 's/.*Core area (dbu): *\([0-9]* [0-9]* [0-9]* [0-9]*\).*/\1/p' "$log" 2>/dev/null | tail -1)"
    guide="$(sed -n 's/.*Route guides written: *//p' "$log" 2>/dev/null | tail -1)"
    if [ -z "$core" ]; then
        echo "Nets routed outside the core: not computed (no core area in ${log})"
        return 0
    elif [ -z "$guide" ] || [ ! -f "$guide" ]; then
        echo "Nets routed outside the core: not computed (grt wrote no route guides)"
        return 0
    fi
    # shellcheck disable=SC2086 # $core is four numbers, split on purpose
    n="$(set -- $core; awk -v x0="$1" -v y0="$2" -v x1="$3" -v y1="$4" '
        $1 == "(" { out = 0; next }
        $1 == ")" { if (out) n++; next }
        NF >= 5 && !out {
            cx = ($1 + $3) / 2; cy = ($2 + $4) / 2
            if (cx < x0 || cx > x1 || cy < y0 || cy > y1) out = 1
        }
        END { print n + 0 }' "$guide")"
    echo "Nets routed outside the core: ${n:-not computed (awk failed)}"
}

# Detailed-route outcome from the router's own counts (specs/pnr-flow
# "Detailed routing reports the router's own violation counts";
# drc-clean-pnr design D2). Reads pnr_drt.log: every `DRT-0199 Number of
# violations = N` line, one per iteration, and the `Viol/Layer` table after
# the last of them (the final iteration by type and layer). Writes both to
# <proj>.drt.violations.txt and appends `drt-violations final=<N>
# iterations=<k> trajectory=<n0,...>` to pnr_status.log, or
# `drt-violations none` when the router logged no count. Deliberately not
# the DRC report file: OpenROAD caps that at 10,000 markers per violation
# type, so run 38473439796's listed 21,110 entries where the router counted
# 715,558. Runs whether drt reached its budget, converged, failed or timed
# out. Never changes the exit status.
report_drt_outcome() {
    local log="${REPORTS}/pnr_drt.log" out="${REPORTS}/${PROJ_NAME}.drt.violations.txt"
    local counts n final trajectory
    counts="$(awk '/DRT-0199\]/ && /Number of violations =/ {
        v = $NF; sub(/\.$/, "", v); print v }' "$log" 2>/dev/null)"
    if [ -z "$counts" ]; then
        echo "Detailed-route violations: none reported (no DRT-0199 line in ${log})" | tee "$out"
        log_status drt-violations none ""
        return 0
    fi
    n="$(grep -c . <<< "$counts")"
    final="$(tail -1 <<< "$counts")"
    trajectory="$(paste -sd, - <<< "$counts")"
    {
        echo "Detailed-route violations: the router's own counts (DRT-0199 in pnr_drt.log)"
        echo
        echo "iteration  violations"
        awk '{ printf "%9d  %10d\n", NR - 1, $1 }' <<< "$counts"
        echo
        echo "Final iteration by type and layer:"
        # The table follows its DRT-0199 line and ends at the next log line
        # ([INFO ...]) or a blank one. A clean iteration may print none.
        awk '/DRT-0199\]/ { table = ""; grab = 0; next }
             /^Viol\/Layer/ { table = $0 "\n"; grab = 1; next }
             grab && (/^\[/ || /^[[:space:]]*$/) { grab = 0 }
             grab { table = table $0 "\n" }
             END { printf "%s", (table == "" ? "(no table logged)\n" : table) }' "$log"
    } > "$out"
    log_status drt-violations "final=${final}" "iterations=${n} trajectory=${trajectory}"
    echo "Detailed-route violations (router's count): final ${final} after ${n} iteration(s), trajectory ${trajectory}"
    cat "$out"
}

# Antenna outcome of the routed design (specs/pnr-flow "Detailed routing
# reports the antenna checker's own counts"; drc-clean-sram-metal5-and-antenna
# design D3). drt.tcl runs check_antennas after detailed_route; this reads the
# last `ANT-0002 Found N net violations` and `ANT-0001 Found M pin
# violations` from pnr_drt.log and appends `drt-antenna nets=<N> pins=<M>`
# to pnr_status.log. Counts are reported only when drt saved its checkpoint,
# i.e. produced a routed design; otherwise, or when the checker logged no
# count, the row is `drt-antenna none`, never zero. The full listing is
# <proj>_antenna.rpt. Never changes the exit status.
report_antenna_outcome() {
    local log="${REPORTS}/pnr_drt.log" nets pins
    if [ ! -f "$(checkpoint_zip drt)" ]; then
        echo "Antenna violations: none reported (drt saved no routed design)"
        log_status drt-antenna none "no-routed-design"
        return 0
    fi
    nets="$(sed -n 's/.*ANT-0002\] Found \([0-9]*\) net violations.*/\1/p' "$log" 2>/dev/null | tail -1)"
    pins="$(sed -n 's/.*ANT-0001\] Found \([0-9]*\) pin violations.*/\1/p' "$log" 2>/dev/null | tail -1)"
    if [ -z "$nets" ] || [ -z "$pins" ]; then
        echo "Antenna violations: none reported (no ANT-0002/ANT-0001 count in ${log})"
        log_status drt-antenna none "no-checker-count"
        return 0
    fi
    log_status drt-antenna "nets=${nets}" "pins=${pins}"
    echo "Antenna violations (checker's count): ${nets} nets, ${pins} pins (${PROJ_NAME}_antenna.rpt)"
}

past_gate=0
overall_rc=0
best_effort_broken=0

for stage in "${STAGES[@]}"; do
    zip_path="$(checkpoint_zip "$stage")"

    if [ "$past_gate" -eq 1 ] && [ "$best_effort_broken" -eq 1 ]; then
        echo "Skipping best-effort stage '${stage}': an earlier best-effort stage failed, its checkpoint is unavailable."
        log_status "$stage" skipped "predecessor-failed"
        continue
    fi

    if [ -f "$zip_path" ]; then
        echo "Stage '${stage}' already has checkpoint ${zip_path} - resuming past it."
        log_status "$stage" skipped "resume"
        [ "$stage" = "$GATE" ] && past_gate=1
        if stop_here "$stage"; then
            echo "PNR_STOP_AFTER=${STOP_AFTER} satisfied (from checkpoint) - not running the remaining stages."
            break
        fi
        continue
    fi

    if [ "${PNR_DRY_RUN:-0}" = "1" ]; then
        gate_note="best-effort"
        [ "$past_gate" -eq 1 ] || gate_note="gated"
        [ "$stage" = "$GATE" ] && gate_note="gated, GATE"
        echo "[dry-run] would run stage '${stage}' (${gate_note}; timeout $(stage_timeout "$stage")s, retries ${STAGE_RETRIES[$stage]}) -> ${zip_path}"
        [ "$stage" = "$GATE" ] && past_gate=1
        if stop_here "$stage"; then
            echo "[dry-run] PNR_STOP_AFTER=${STOP_AFTER} reached - would not run the remaining stages."
            break
        fi
        continue
    fi

    attempt=0
    max_attempts=$(( STAGE_RETRIES[$stage] + 1 ))
    rc=1
    while [ "$attempt" -lt "$max_attempts" ]; do
        attempt=$((attempt + 1))
        # Deliberately not `if run_stage_once ...; then` - when the
        # condition is false and there's no `else`, bash's `if` construct
        # itself exits 0, which would clobber the real (failing) return
        # code before we ever read it. Call it as a plain statement and
        # read $? immediately instead.
        run_stage_once "$stage"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            break
        fi
        if [ "$attempt" -lt "$max_attempts" ]; then
            echo "::warning::stage '${stage}' failed (exit ${rc}) on attempt ${attempt}/${max_attempts} - retrying from its predecessor checkpoint"
            log_status "$stage" retrying "attempt=${attempt} exit=${rc}"
        fi
    done

    [ "$stage" = "dpl" ] && report_placement_state
    [ "$stage" = "grt" ] && report_routes_outside_core
    [ "$stage" = "drt" ] && report_drt_outcome
    [ "$stage" = "drt" ] && report_antenna_outcome

    if [ "$rc" -ne 0 ]; then
        echo "::error::stage '${stage}' failed after ${attempt} attempt(s), exit ${rc}"
        log_status "$stage" failed "exit=${rc} attempts=${attempt}"
        if [ "$past_gate" -eq 0 ]; then
            # This stage is at-or-before the gate: the run cannot proceed
            # (no checkpoint for the next stage to load) and the gate
            # itself did not clear.
            overall_rc=1
            [ "$stage" = "$GATE" ] && past_gate=1
            break
        else
            # Best-effort stage after the gate: record and let the loop
            # skip everything downstream via the predecessor-failed check.
            best_effort_broken=1
        fi
    else
        [ "$stage" = "$GATE" ] && past_gate=1
        if stop_here "$stage"; then
            echo "PNR_STOP_AFTER=${STOP_AFTER} completed - not running the remaining stages."
            log_status "$stage" stop-after ""
            break
        fi
    fi
done

if [ "${PNR_DRY_RUN:-0}" = "1" ]; then
    echo "Dry run complete - no OpenROAD process was started."
    exit 0
fi

if [ "$past_gate" -ne 1 ]; then
    # Gate stage never even ran (e.g. an earlier stage failed) - the flow
    # never reached the gate at all, which is a failure regardless of
    # overall_rc's current value.
    overall_rc=1
fi

echo "P&R driver finished. Gate stage: ${GATE}. Status log: ${STATUS_LOG}"
exit "$overall_rc"
