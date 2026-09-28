#!/usr/bin/env bash
# Copyright 2026 Kyiv School of Economics.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Host side: archives a staged bundle as OUT_DIR/<bundle_id>.tar.gz with a
# single top-level directory named <bundle_id>. Portable across GNU tar and
# bsdtar (macOS) by packing through a symlink and dereferencing it (-h).
#
# Usage: pack.sh STAGE_DIR OUT_DIR

set -euo pipefail

stage=$(cd "$1" && pwd)
out=$(mkdir -p "$2" && cd "$2" && pwd)

"$stage/check-bundle.sh" "$stage"

id=$(cat "$stage/BUNDLE_ID")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ln -s "$stage" "$tmp/$id"

archive="$out/$id.tar.gz"
# macOS bsdtar would embed xattrs/AppleDouble data that GNU tar on the VM
# warns about or extracts as ._* junk.
extra=""
if tar --version 2>/dev/null | grep -q bsdtar; then
  extra="--no-xattrs --no-mac-metadata"
  export COPYFILE_DISABLE=1
fi
# shellcheck disable=SC2086
tar $extra -C "$tmp" -chzf "$archive.tmp" "$id"
mv "$archive.tmp" "$archive"
echo "pack.sh: wrote $archive ($(du -h "$archive" | cut -f1))"
echo "pack.sh: copy it to the VM, then: tar xzf $id.tar.gz && cd $id && ./run.sh"
