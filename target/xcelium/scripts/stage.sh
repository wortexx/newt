#!/usr/bin/env bash
# Copyright 2026 Kyiv School of Economics.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Host side: turns Bender's absolute flist-plus into a bundle-relative xrun.f
# and stages every file it references, plus ELFs, scripts and a MANIFEST, into
# $STAGE. Driven by xcelium.mk (ig-xrun-stage), which sets the variables below.
# Must stay bash-3.2 compatible (macOS host).

set -euo pipefail

: "${IG_ROOT:?}" "${STAGE:?}" "${RAW_FLIST:?}" "${EXCLUDE_PATTERN:?}"
: "${EXTRA_SRCS:?}" "${LANE_DIR:?}" "${BENDER:=bender}"
ELFS="${ELFS:-}"

die() { echo "stage.sh: ERROR: $*" >&2; exit 1; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

[ -n "$ELFS" ] || die "no test ELFs found - build them first with 'make ig-sw-all' (or set XRUN_ELFS=...)"

rm -rf "$STAGE"
mkdir -p "$STAGE/elf"

# xrun.f: strip the repo prefix, drop the Questa full-chip fixture, append the
# lane's own testbench + DPI sources, and de-duplicate (Bender lists a few
# files under two targets) keeping first occurrence so compile order holds.
{
  cat "$RAW_FLIST"
  for f in $EXTRA_SRCS; do echo "$f"; done
} | sed -e "s|^\(+incdir+\)\{0,1\}${IG_ROOT}/|\1|" \
  | awk -v ex="$EXCLUDE_PATTERN" -v keep="${KEEP_PATTERN:-^$}" \
      '($0 !~ ex || $0 ~ keep) && NF && !seen[$0]++' > "$STAGE/xrun.f"

# Copy every referenced file and include directory, preserving repo-relative
# paths. -h dereferences symlinks so the VM gets real files.
listfile="$(dirname "$STAGE")/copylist.txt"
awk '/^\+incdir\+/ { sub(/^\+incdir\+/, ""); print; next } /^\+/ { next } { print }' \
  "$STAGE/xrun.f" | sort -u > "$listfile"
if grep -q '^/' "$listfile"; then
  die "file list has entries outside the repository:
$(grep '^/' "$listfile" | head -5)"
fi
(cd "$IG_ROOT" && tar -chf - -T "$listfile") | (cd "$STAGE" && tar -xf -)

# Headers Bender lists as sources (CVA6's *_trace_item.svh) are `include`d by
# the files that use them; compiling them standalone as well makes Xcelium
# report every declaration twice (*E,DUPIDN). They stay in the bundle, reached
# through +incdir+, but leave the compile list.
grep -v '\.svh$' "$STAGE/xrun.f" > "$STAGE/xrun.f.tmp"
mv "$STAGE/xrun.f.tmp" "$STAGE/xrun.f"

# Nothing in the bundle may live under a hidden directory: many copy paths to
# the VM (GUI/portal uploads, `cp dir/*`, transfer filters) silently drop
# dot-directories. Bender's checkouts move from .bender/git/checkouts/ to deps/.
if [ -d "$STAGE/.bender/git/checkouts" ]; then
  mv "$STAGE/.bender/git/checkouts" "$STAGE/deps"
  rm -rf "$STAGE/.bender"
  sed -e 's|^\(+incdir+\)\{0,1\}\.bender/git/checkouts/|\1deps/|' "$STAGE/xrun.f" > "$STAGE/xrun.f.tmp"
  mv "$STAGE/xrun.f.tmp" "$STAGE/xrun.f"
fi

elf_list=""
for e in $ELFS; do
  [ -f "$e" ] || die "test ELF not found: $e (run 'make ig-sw-all' first)"
  cp "$e" "$STAGE/elf/"
  elf_list="$elf_list $(basename "$e")"
done

cp "$LANE_DIR/run.sh" "$LANE_DIR/check-bundle.sh" "$STAGE/"
chmod +x "$STAGE/run.sh" "$STAGE/check-bundle.sh"

# Provenance. Deliberately no wall-clock date, so re-staging the same tree
# yields byte-identical output; the commit date pins it in time instead.
cd "$IG_ROOT"
commit=$(git rev-parse HEAD)
short=$(git rev-parse --short HEAD)
# Dirty = any tracked change anywhere, or any untracked file that ends up in
# the bundle (e.g. a new, not-yet-committed testbench source).
dirty=no
if [ -n "$(git status --porcelain --untracked-files=no)" ] ||
   [ -n "$(xargs git status --porcelain --untracked-files=all -- target/xcelium < "$listfile")" ]; then
  dirty=yes
fi
bundle_id="newt-xrun-$short"
[ "$dirty" = no ] || bundle_id="$bundle_id-dirty"

{
  echo "bundle_id:        $bundle_id"
  echo "commit:           $commit"
  echo "commit_date:      $(git log -1 --format=%cI HEAD)"
  echo "working_tree:     $([ "$dirty" = yes ] && echo 'DIRTY (uncommitted changes)' || echo clean)"
  echo "bender_lock_sha:  $(sha256 Bender.lock)"
  echo "bender:           $($BENDER --version 2>/dev/null | head -1)"
  echo "host:             $(uname -sm)"
  echo "expected_xrun:    24.03-s004"
  # Cheshire's linker scripts drop .comment, so the ELFs cannot name their
  # compiler; their hashes pin them instead.
  echo "tests:            (prebuilt by ig-sw-all; compiler not recorded in the ELFs)"
  for e in $elf_list; do
    echo "  - $e  sha256=$(sha256 "$STAGE/elf/$e")"
  done
} > "$STAGE/MANIFEST"
echo "$bundle_id" > "$STAGE/BUNDLE_ID"
rm -f "$listfile"

"$STAGE/check-bundle.sh" "$STAGE"
size=$(du -sh "$STAGE" | cut -f1)
n_elfs=$(echo "$elf_list" | wc -w | tr -d '[:space:]')
echo "stage.sh: staged $bundle_id in $STAGE ($size, $n_elfs ELFs)"
