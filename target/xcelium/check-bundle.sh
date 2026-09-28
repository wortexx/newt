#!/usr/bin/env bash
# Copyright 2026 Kyiv School of Economics.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Bundle completeness check: every file/include dir named in xrun.f must exist
# inside the bundle, relative to its root, with nothing absolute or escaping
# it. Runs on the host before archiving (a broken path costs a VM round trip
# otherwise) and again on the VM from run.sh.
#
# Usage: check-bundle.sh [BUNDLE_ROOT]   (default: this script's directory)

set -uo pipefail

root="${1:-$(cd "$(dirname "$0")" && pwd)}"
cd "$root" || { echo "check-bundle: cannot enter $root" >&2; exit 1; }

errors=0
fail() { echo "check-bundle: $*" >&2; errors=$((errors + 1)); }

[ -f xrun.f ] || { echo "check-bundle: no xrun.f in $root" >&2; exit 1; }

check_path() { # kind path
  case "$2" in
    /*)                  fail "absolute path in xrun.f: $2"; return ;;
    ../*|*/../*|*/..|..) fail "path escapes the bundle: $2"; return ;;
  esac
  if [ "$1" = dir ]; then
    [ -d "$2" ] || fail "missing include directory: $2"
  else
    [ -f "$2" ] || fail "missing file: $2"
  fi
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'//'*|'#'*) ;;
    +incdir+*)     check_path dir "${line#+incdir+}" ;;
    +define+*)     ;;
    [+-]*)         fail "unexpected option in xrun.f: $line" ;;
    *)             check_path file "$line" ;;
  esac
done < xrun.f

# cheshire.mk's 24FC1025 rule uses `wget -o` (log file), which only works by
# accident; make sure what we carry is the model and not a wget log.
eeprom=$(grep -m1 '/24FC1025\.v$' xrun.f || true)
if [ -z "$eeprom" ]; then
  fail "24FC1025.v (I2C EEPROM model) not in xrun.f"
elif [ -f "$eeprom" ] && ! grep -q 'module M24FC1025' "$eeprom"; then
  fail "$eeprom does not define module M24FC1025 (a wget log instead of the model?)"
fi

ls elf/*.elf >/dev/null 2>&1 || fail "no test ELFs in elf/"
for f in run.sh MANIFEST BUNDLE_ID; do
  [ -f "$f" ] || fail "missing $f"
done

if [ "$errors" -ne 0 ]; then
  echo "check-bundle: FAILED ($errors problem(s)) in $root" >&2
  exit 1
fi
n_files=$(grep -cv '^+' xrun.f)
n_incdirs=$(grep -c '^+incdir+' xrun.f)
n_elfs=$(find elf -name '*.elf' | wc -l | tr -d '[:space:]')
echo "check-bundle: OK ($n_files files, $n_incdirs include dirs, $n_elfs ELFs)"
