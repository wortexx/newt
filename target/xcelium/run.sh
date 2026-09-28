#!/usr/bin/env bash
# Copyright 2026 Kyiv School of Economics.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# VM side of the Xcelium lane: run from an extracted bundle. Compiles and
# elaborates once, runs each selected test ELF against that snapshot, writes a
# per-test verdict, and packs everything into ONE results archive to copy back.
# Needs only xrun, bash and POSIX utilities.
#
# Usage: ./run.sh [TEST ...]      (TEST = ELF name, with or without .elf;
#                                   default: every ELF in elf/)
# Settings (environment):
#   BOOTMODE=0        0 = idle boot + preload; 2/3 = autonomous (needs IMAGE)
#   PRELMODE=0        0 = JTAG, 1 = serial link, 2 = UART   (BOOTMODE=0 only)
#   IMAGE=            memh image for BOOTMODE 2/3
#   TIMEOUT_NS=10000000   simulated-time bound per test
#   WAVES=none        none | vcd (debug path only) | shm (everything)
#   WALL_TIMEOUT_S=7200   wall-clock bound per test (needs `timeout`; 0 = off)
#   XRUN=xrun  XRUN_COMP_ARGS=  XRUN_RUN_ARGS=   extra/override tool args
# Exit status: 0 only if every executed test is PASS.

set -uo pipefail

cd "$(dirname "$0")" || exit 2
root=$(pwd)

if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
  sed -n '/^# Usage/,/^# Exit status/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

XRUN=${XRUN:-xrun}
BOOTMODE=${BOOTMODE:-0}
PRELMODE=${PRELMODE:-0}
IMAGE=${IMAGE:-}
TIMEOUT_NS=${TIMEOUT_NS:-10000000}
WAVES=${WAVES:-none}
WALL_TIMEOUT_S=${WALL_TIMEOUT_S:-7200}
XRUN_COMP_ARGS=${XRUN_COMP_ARGS:-}
XRUN_RUN_ARGS=${XRUN_RUN_ARGS:-}

TOP=tb_newt_xrun
LIBDIR=build/xcelium.d
DUT=$TOP.fix.i_dut.i_cheshire_soc

bundle_id=$(cat BUNDLE_ID 2>/dev/null || echo newt-xrun-unknown)
res_name="$bundle_id-results-$(date +%Y%m%d-%H%M%S)"

rm -rf results
mkdir -p results

# --- test selection ---------------------------------------------------------
tests=""
if [ $# -eq 0 ]; then
  for f in elf/*.elf; do
    [ -f "$f" ] && tests="$tests $(basename "$f" .elf)"
  done
else
  for a in "$@"; do
    a=$(basename "$a"); tests="$tests ${a%.elf}"
  done
fi

verdicts=""   # lines of "test verdict exit detail"
record() { verdicts="$verdicts$1|$2|$3|$4
"; }

setup_error=""
[ -n "$tests" ] || setup_error="no tests selected and no ELFs in elf/"
case "$WAVES" in none|vcd|shm) ;; *) setup_error="WAVES must be none, vcd or shm (got '$WAVES')" ;; esac
command -v "$XRUN" >/dev/null 2>&1 || setup_error="'$XRUN' not found on PATH"

{
  echo "bundle:          $bundle_id"
  echo "host:            $(uname -snrm)"
  echo "date:            $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "tests:          $tests"
  echo "BOOTMODE=$BOOTMODE PRELMODE=$PRELMODE IMAGE=$IMAGE TIMEOUT_NS=$TIMEOUT_NS WAVES=$WAVES WALL_TIMEOUT_S=$WALL_TIMEOUT_S"
  echo "XRUN=$XRUN XRUN_COMP_ARGS=$XRUN_COMP_ARGS XRUN_RUN_ARGS=$XRUN_RUN_ARGS"
} > results/settings.txt

# --- compile + elaborate once -------------------------------------------------
compile=SKIPPED
if [ -z "$setup_error" ]; then
  "$XRUN" -version > results/xrun-version.txt 2>&1
  if ! ./check-bundle.sh "$root" > results/check-bundle.log 2>&1; then
    setup_error="bundle check failed (see check-bundle.log)"
  fi
fi

if [ -z "$setup_error" ]; then
  access=""
  [ "$WAVES" = none ] || access="-access +r"
  echo "run.sh: compiling (log: results/compile.log) ..."
  # xrun creates -xmlibdirname itself but not its parent (*E,NWRKDRA).
  rm -rf build
  mkdir -p build
  # shellcheck disable=SC2086  # $access / $XRUN_COMP_ARGS are word lists
  if "$XRUN" -64bit -elaborate -sv -timescale 1ns/1ps \
      -xmlibdirname "$LIBDIR" -top "$TOP" -f xrun.f $access \
      -l results/compile.log $XRUN_COMP_ARGS > /dev/null 2>&1; then
    compile=OK
  else
    compile=FAILED
    setup_error="compile/elaboration failed (see compile.log)"
    tail -20 results/compile.log 2>/dev/null | sed 's/^/  | /'
  fi
fi

# --- run each test --------------------------------------------------------------
wave_script() { # test_dir
  case "$WAVES" in
    vcd) cat <<EOF
database -open newt_waves -vcd -into $1/waves.vcd -default
probe -create $TOP.fix -depth 1 -database newt_waves
probe -create $DUT.i_dbg_dmi_jtag -depth all -database newt_waves
probe -create $DUT.i_dbg_dm_top -depth all -database newt_waves
probe -create {$DUT.gen_cva6_cores[0].i_core_cva6} -depth 1 -database newt_waves
run
exit
EOF
    ;;
    shm) cat <<EOF
database -open newt_waves -shm -into $1/waves.shm -default
probe -create $TOP -all -depth all -database newt_waves
run
exit
EOF
    ;;
  esac
}

for t in $tests; do
  if [ -n "$setup_error" ]; then record "$t" ERROR - "$setup_error"; continue; fi
  elf="$root/elf/$t.elf"
  if [ ! -f "$elf" ]; then record "$t" ERROR - "no such ELF in bundle"; continue; fi

  d="results/$t"
  mkdir -p "$d"
  args="+BINARY=$elf +BOOTMODE=$BOOTMODE +PRELMODE=$PRELMODE +TIMEOUT_NS=$TIMEOUT_NS"
  [ -z "$IMAGE" ] || args="$args +IMAGE=$IMAGE"
  if [ "$WAVES" != none ]; then
    wave_script "$d" > "$d/waves.tcl"
    args="$args -input $d/waves.tcl"
  fi

  wrap=""
  if [ "$WALL_TIMEOUT_S" -gt 0 ] 2>/dev/null && command -v timeout >/dev/null 2>&1; then
    wrap="timeout $WALL_TIMEOUT_S"
  fi

  echo "run.sh: running $t ..."
  # shellcheck disable=SC2086
  $wrap "$XRUN" -R -64bit -xmlibdirname "$LIBDIR" $args \
    -l "$d/run.log" $XRUN_RUN_ARGS > /dev/null 2>&1
  rc=$?

  marker=$(sed -n 's/.*\[NEWT-XRUN\] RESULT \(.*\)$/\1/p' "$d/run.log" 2>/dev/null | head -1)
  case "$marker" in
    EXIT=0)        record "$t" PASS 0 "" ;;
    EXIT=*)        record "$t" FAIL "${marker#EXIT=}" "" ;;
    TIMEOUT)       record "$t" TIMEOUT - "simulated time > ${TIMEOUT_NS} ns" ;;
    UNSUPPORTED*)  record "$t" ERROR - "$marker" ;;
    *)
      if [ -n "$wrap" ] && [ "$rc" -eq 124 ]; then
        record "$t" TIMEOUT - "wall clock > ${WALL_TIMEOUT_S} s"
      else
        record "$t" ERROR - "no RESULT marker (xrun rc=$rc, see run.log)"
      fi ;;
  esac
done

# --- summary + archive ----------------------------------------------------------
all_pass=1
{
  echo "bundle:   $bundle_id"
  echo "settings: BOOTMODE=$BOOTMODE PRELMODE=$PRELMODE TIMEOUT_NS=$TIMEOUT_NS WAVES=$WAVES"
  echo "compile:  $compile"
  [ -z "$setup_error" ] || echo "error:    $setup_error"
  echo
  printf '%-28s %-8s %-6s %s\n' TEST VERDICT EXIT DETAIL
  printf '%s' "$verdicts" | while IFS='|' read -r t v c det; do
    [ -n "$t" ] && printf '%-28s %-8s %-6s %s\n' "$t" "$v" "$c" "$det"
  done
} > results/summary.txt
if [ -z "$verdicts" ] || printf '%s' "$verdicts" | grep -qv '|PASS|'; then
  all_pass=0
fi

cp MANIFEST results/ 2>/dev/null
ln -s results "$res_name"
tar -chzf "$res_name.tar.gz" "$res_name"
rm -f "$res_name"

echo
cat results/summary.txt
echo
echo "run.sh: results archive: $root/$res_name.tar.gz  (copy this file back)"
[ "$all_pass" -eq 1 ]
