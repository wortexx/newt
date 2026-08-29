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
ARG BENDER_TAR=https://github.com/pulp-platform/bender/releases/download/v0.27.4/bender-0.27.4-x86_64-linux-gnu.tar.gz
ARG MORTY_REPO=https://github.com/pulp-platform/morty
ARG MORTY_COMMIT=v0.9.0
ARG SVASE_REPO=https://github.com/pulp-platform/svase
ARG SVASE_COMMIT=f5f5290d57ff6f6ffbc06bcb5099b9d76a67f454
ARG SV2V_REPO=https://github.com/zachjs/sv2v
ARG SV2V_COMMIT=v0.0.11

ENV DEBIAN_FRONTEND=noninteractive
# install packages (keep the apt cache around: both installers below shell out
# to their own "apt-get install" and need a live package index)
COPY packages.txt /packages.txt
RUN apt-get update && \
    apt-get install -y --no-install-recommends $(cat /packages.txt)
# install rust cargo (morty); pinned to a toolchain contemporaneous with
# morty v0.9.0's Cargo.lock (released 2023-02) - "latest stable" rustc
# eventually turns sv-parser-parser 0.12.1's ambiguous glob imports (E0659)
# into a hard error, and that dependency version is locked, not something
# we can bump without touching morty's own pin
RUN curl https://sh.rustup.rs -sSf | bash -s -- -y --default-toolchain 1.67.0
ENV PATH="/root/.cargo/bin:$PATH"
# install haskell stack (sv2v)
RUN curl -sSL https://get.haskellstack.org/ | bash
RUN rm -rf /var/lib/apt/lists/*


WORKDIR /build/bin
RUN curl -L ${BENDER_TAR} | tar -xzC .

WORKDIR /morty
RUN curl -L ${MORTY_REPO}/archive/${MORTY_COMMIT}.tar.gz | tar -xzC . --strip-components=1 && \
    cargo build --release --locked && \
    cp target/release/morty /build/bin/morty

# ToDo: submodules lose their correct versions if done via archive -> fix in svase?
WORKDIR /svase
RUN git clone ${SVASE_REPO}.git . && git checkout ${SVASE_COMMIT} && \
    git submodule update --init --recursive && \
    export CXX=clang++-16 && \
    make -j && \
    cp build/svase /build/bin/svase

WORKDIR /sv2v
RUN curl -L ${SV2V_REPO}/archive/${SV2V_COMMIT}.tar.gz | tar -xzC . --strip-components=1 && \
    make -j && \
    cp bin/sv2v /build/bin/sv2v

# copy into runnner
FROM ${DOCKER_BASE_IMG} AS runner
COPY --from=builder /build /build
ENV PATH /build/bin:$PATH
