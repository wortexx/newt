# Copyright (c) 2022 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Philippe Sauter <phsauter@ethz.ch>
#
# based on: https://docs.docker.com/build/building/multi-stage/
# syntax=docker/dockerfile:1
ARG DOCKER_BASE_IMG=ubuntu:24.04

FROM ${DOCKER_BASE_IMG} AS builder
# Upstream YosysHQ/yosys, pinned by release tag. This replaces the custom
# fork the flow used until 2026-09 (upstream 2024-04 plus 3 commits on
# passes/techmap/abc.cc): that fork's -liberty_args feature landed upstream
# in v0.66 (PR #5721), and v0.67+ is the first yosys with the slang
# SystemVerilog frontend built in, which the Phase 8 frontend work needs.
# Full rationale: openspec/changes/upgrade-yosys-upstream/design.md (D1).
# Bump this tag only via a change that re-runs the synthesis adoption gate.
ARG YOSYS_VERSION=v0.69
ENV DEBIAN_FRONTEND=noninteractive
# install packages
COPY packages.txt /packages.txt
RUN apt-get update && \
    apt-get install -y --no-install-recommends $(cat /packages.txt) && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /yosys
# Pull and build.
#
# The release asset `yosys.tar.gz` (not GitHub's auto-generated
# archive/<ref>.tar.gz) is used because upstream vendors abc, slang, fmt,
# cxxopts, tomlplusplus and boost_regex as git submodules, which the
# auto-generated archives omit entirely - that tree does not build. The
# release asset bundles them, so no `git submodule update` (and no network
# access during configure) is needed.
#
# NOTE: unlike the auto-generated archives, this tarball has NO top-level
# directory - its members start at `CMakeLists.txt`, `abc/`, `libs/`. Do not
# add `--strip-components=1` here; it would silently drop the entire tree.
#
# The cmake invocation mirrors upstream's own reference build
# (.github/workflows/test-build.yml) plus an install prefix:
#   YOSYS_USE_BUNDLED_LIBS=ON  use the vendored third-party libs instead of
#                              probing for system ones - deterministic, and
#                              correct for this offline tarball build
#   BUILD_SHARED_LIBS=OFF      libyosys as a static archive. The driver links
#                              its components (OBJECT libraries) directly, so
#                              nothing in /build depends on a .so that the
#                              copy-only runner stage below would not receive
#   YOSYS_ENABLE_UNIT_TESTS=OFF  the image ships a tool, not a test suite
# In-tree builds are rejected by upstream's CMakeLists, hence `-B build`.
RUN curl -L https://github.com/YosysHQ/yosys/releases/download/${YOSYS_VERSION}/yosys.tar.gz | tar -xzC . && \
    cmake -B build . \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/build \
        -DYOSYS_USE_BUNDLED_LIBS=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DYOSYS_ENABLE_UNIT_TESTS=OFF && \
    cmake --build build -j$(nproc) && \
    cmake --install build

# copy into runnner
FROM ${DOCKER_BASE_IMG} AS runner
COPY --from=builder /build /build
ENV PATH /build/bin:$PATH
