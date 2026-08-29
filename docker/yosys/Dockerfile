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
ARG YOSYS_REPO=https://github.com/phsauter/yosys
ARG YOSYS_COMMIT=3ce5059a88c987cab4df665ab347bc88e8401824
ENV DEBIAN_FRONTEND=noninteractive
# install packages
COPY packages.txt /packages.txt
RUN apt-get update && \
    apt-get install -y --no-install-recommends $(cat /packages.txt) && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /yosys
# pull and build
RUN curl -L ${YOSYS_REPO}/archive/${YOSYS_COMMIT}.tar.gz | tar -xzC . --strip-components=1 && \
    make config-clang && \
    make -j && \
    make PREFIX=/build install

# copy into runnner
FROM ${DOCKER_BASE_IMG} AS runner
COPY --from=builder /build /build
ENV PATH /build/bin:$PATH
