#!/usr/bin/env bash
# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Fetch IHP's KLayout tech (DRC runner, rule decks, seal-ring PCell code) from
# one pinned IHP-Open-PDK commit into <root>, apart from the PDK submodule whose
# LEF/Liberty/GDS views the flow uses (change seal-and-drc-gds, design D1).
#
#   fetch_klayout_tech.sh <root> <repo-url> <commit>
#
# Sparse and blobless: versions.txt (run_drc.py reads it for its KLayout version
# check) and ihp-sg13g2/libs.tech/klayout without test data, then the
# pycell4klayout-api submodule (the seal ring's `cni`) at the commit's gitlink.
# The repo layout is kept, so run_drc.py's relative lookups work. Idempotent:
# a stamp matching <commit> means no network access.

set -euo pipefail

root=$1
repo=$2
rev=$3
stamp="$root/.newt-klayout-tech"
sub=ihp-sg13g2/libs.tech/klayout/python/pycell4klayout-api

# Git refuses a repository owned by another user (a container on a host
# checkout) unless it is a safe.directory. Mark our two checkouts safe through
# GIT_CONFIG_* (protected, command-scope config), appended to any entries
# already set - the P&R lane uses them for its buildroot redirect.
safe_dir() {
    local n=${GIT_CONFIG_COUNT:-0}
    export "GIT_CONFIG_KEY_$n=safe.directory" "GIT_CONFIG_VALUE_$n=$1"
    export GIT_CONFIG_COUNT=$((n + 1))
}
mkdir -p "$root"
root=$(cd "$root" && pwd)
safe_dir "$root"
safe_dir "$root/$sub"

if [[ -f "$stamp" && "$(cat "$stamp")" == "$rev" ]] &&
   [[ "$(git -C "$root" rev-parse HEAD 2>/dev/null)" == "$rev" ]] &&
   [[ -d "$root/$sub/source/python/cni" ]]; then
    echo "KLayout tech up to date: IHP-Open-PDK ${rev:0:10} in $root"
    exit 0
fi

if [[ -n "$(ls -A "$root")" ]]; then
    old=$(git -C "$root" rev-parse --verify -q HEAD 2>/dev/null || echo none)
    echo "KLayout tech at $old, pin is $rev: refetching $root"
    rm -rf "${root:?}"
    mkdir -p "$root"
fi

git -C "$root" init -q
git -C "$root" remote add origin "$repo"
git -C "$root" sparse-checkout set --no-cone \
    '/versions.txt' \
    '/ihp-sg13g2/libs.tech/klayout/' \
    '!/ihp-sg13g2/libs.tech/klayout/**/testing/' \
    '!/ihp-sg13g2/libs.tech/klayout/sg13g2_tests/'
git -C "$root" fetch -q --depth 1 --filter=blob:none origin "$rev"
git -C "$root" -c advice.detachedHead=false checkout -q FETCH_HEAD

head=$(git -C "$root" rev-parse HEAD)
if [[ "$head" != "$rev" ]]; then
    echo "ERROR: fetched $head, pin is $rev" >&2
    exit 1
fi

# The submodule as the pinned commit records it: URL from .gitmodules, commit
# from the gitlink in the tree.
sub_url=$(git -C "$root" show HEAD:.gitmodules |
          git config -f /dev/stdin --get "submodule.$sub.url")
sub_rev=$(git -C "$root" ls-tree HEAD "$sub" | awk '{print $3}')
if [[ -z "$sub_url" || -z "$sub_rev" ]]; then
    echo "ERROR: $sub not found in IHP-Open-PDK $rev" >&2
    exit 1
fi
rm -rf "${root:?}/$sub"
mkdir -p "$root/$sub"
git -C "$root/$sub" init -q
git -C "$root/$sub" remote add origin "$sub_url"
git -C "$root/$sub" fetch -q --depth 1 origin "$sub_rev"
git -C "$root/$sub" -c advice.detachedHead=false checkout -q FETCH_HEAD

echo "$rev" > "$stamp"
echo "KLayout tech: IHP-Open-PDK ${rev:0:10}, pycell4klayout-api ${sub_rev:0:10} in $root"
