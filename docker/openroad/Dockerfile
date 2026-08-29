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
ARG OR_REPO=https://github.com/The-OpenROAD-Project/OpenROAD
# OpenROAD does not cut regular tagged releases (last tag: v0.9.0-beta, 2020);
# pin to a recent master commit instead and bump periodically.
ARG OR_COMMIT=2c569269719c59ef6eef90bcc33f8bc7afc16c02
# install packages
COPY packages.txt /packages.txt
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y --no-install-recommends $(cat /packages.txt) && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /openroad
# pull; OpenROAD's own etc/DependencyInstaller.sh resolves boost/eigen/lemon/
# spdlog/or-tools/etc for the target OS (replaces the hand-rolled per-library
# builds from the pre-2025 image, see design.md decision D2)
RUN git clone ${OR_REPO}.git . && git checkout ${OR_COMMIT} && \
    git submodule update --init --recursive
RUN ./etc/DependencyInstaller.sh -all

RUN mkdir build && mkdir -p /build/version && mkdir install
RUN cd build && cmake -DCMAKE_INSTALL_PREFIX=$(pwd)/install .. && \
    make -j$(nproc) && \
    make install
RUN cp -r build/install/bin /build/

# carry forward whatever shared libs the built binaries actually link against
# (boost/eigen/or-tools/etc land in system paths via the installer above)
RUN mkdir -p /build/lib && \
    for bin in /build/bin/*; do \
      ldd "$bin" 2>/dev/null | awk '/=> \// {print $3}'; \
    done | sort -u | xargs -r -I{} cp -n {} /build/lib/

# copy into runnner
FROM ${DOCKER_BASE_IMG} AS runner
COPY packages.txt /packages.txt
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y --no-install-recommends $(cat /packages.txt) && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder /build /build
ENV PATH /build/bin:$PATH
ENV LD_LIBRARY_PATH=/build/lib:$LD_LIBRARY_PATH
