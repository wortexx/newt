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
#   PNR_SKIP_ANTENNA_REPAIR Passed through to drt.tcl: skip repair_antennas
#                           (hung ~14h unlogged on this over-capacity design
#                           in run 34389061373; see drt.tcl's comment).
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
#                           scripts/pnr/common.tcl.
#   PNR_GPL_KEEP_RESIZE    Passed through to gpl.tcl: pass 2's
#                           -keep_resize_below_overflow. Empty or unset:
#                           pnr_gpl_keep_resize's default in common.tcl (0,
#                           virtual timing-driven repair); 1.0 is OpenROAD's
#                           default.
#   PNR_DIE_SCALE          Passed through to the floorplan: the core's width
#                           and height relative to the taped-out die. Empty or
#                           unset: pnr_die_scale's default in common.tcl
#                           (1.0, the taped-out 6230 x 5478 um die).
#   PNR_DRY_RUN             If "1", print the planned per-stage commands
#                           (in order, honoring resume-skip) and exit 0
#                           without invoking OpenROAD at all - the cheap
#                           validation path (tasks.md 2.3) for CI/review.
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
# placement ended"; raise-gpl-density-target design D2). One line with what
# decides dpl's legalization time: whether gpl's last pass reverted after a
# divergence (GPL-0999) and at what overflow, the final placement area
# inflation (GPL-1014), dpl's utilization (DPL-0009) and the illegal cells
# the negotiation legalizer starts from (its iteration-0 row). dpl prints the
# last two before it legalizes, so they are there even if the stage later
# times out. Warns when gpl reverted on divergence, the state that left
# 80-220 k illegal cells in the runs on record (docs/infra-plan.md Phase 11).
# Never changes the exit status.
report_placement_state() {
    local gpl="${REPORTS}/pnr_gpl.log" dpl="${REPORTS}/pnr_dpl.log"
    local revert area util illegal
    if [ ! -f "$gpl" ]; then
        echo "Placement: not reported (no ${gpl}; gpl restored from a checkpoint?)."
        return 0
    fi
    revert="$(sed -n 's/.*GPL-0999\] Revert to iter: *\([0-9]*\) overflow: *\([0-9.]*\).*/iter \1, overflow \2/p' \
        "$gpl" 2>/dev/null | tail -1)"
    area="$(sed -n 's/.*GPL-1014\] Final placement area: .*(\([-+0-9.]*%\)).*/\1/p' \
        "$gpl" 2>/dev/null | tail -1)"
    util="$(sed -n 's/.*DPL-0009\] Utilization: *\([0-9.]*%\).*/\1/p' "$dpl" 2>/dev/null | head -1)"
    illegal="$(awk -F'|' '/^ *0 \|/ { gsub(/ /, "", $3); print $3; exit }' "$dpl" 2>/dev/null)"
    local msg="gpl final area ${area:-?}, dpl utilization ${util:-?} (DPL-0009), illegal cells at legalizer iteration 0: ${illegal:-none reported}"
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
