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
ARG RISCV64_REPO=https://github.com/riscv-collab/riscv-gnu-toolchain
# GCC >= 13 / binutils >= 2.40 so -march=rv64gc_zknh is available (keeps the
# Zknh standard-extension option open, see docs/infra-plan.md Phase 1)
ARG RISCV64_TAG=2026.08.27
ENV DEBIAN_FRONTEND=noninteractive
# install packages
COPY packages.txt /packages.txt
RUN apt-get update && \
    apt-get install -y --no-install-recommends $(cat /packages.txt) && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /riscv
# pull and build (bare-metal newlib target)
RUN mkdir -p /build
RUN git clone --recursive --branch ${RISCV64_TAG} ${RISCV64_REPO}.git && \
    cd riscv-gnu-toolchain && ./configure --prefix=/build && make -j$(nproc)

# copy into runnner
FROM ${DOCKER_BASE_IMG} AS runner
COPY --from=builder /build /build
ENV PATH /build/bin:$PATH
