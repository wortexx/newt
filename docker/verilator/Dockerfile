# SPDX-License-Identifier: Apache-2.0
#
# based on: https://docs.docker.com/build/building/multi-stage/
# syntax=docker/dockerfile:1
ARG DOCKER_BASE_IMG=ubuntu:24.04

FROM ${DOCKER_BASE_IMG} AS builder
ARG VERILATOR_REPO=https://github.com/verilator/verilator
ARG VERILATOR_TAG=v5.050
ENV DEBIAN_FRONTEND=noninteractive
COPY packages.txt /packages.txt
RUN apt-get update && \
    apt-get install -y --no-install-recommends $(cat /packages.txt) && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /verilator
RUN git clone --branch ${VERILATOR_TAG} --depth 1 ${VERILATOR_REPO}.git . && \
    autoconf && \
    ./configure --prefix=/build && \
    make -j$(nproc) && \
    make install

# copy into runnner
FROM ${DOCKER_BASE_IMG} AS runner
COPY --from=builder /build /build
ENV PATH /build/bin:$PATH
