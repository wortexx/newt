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
ARG PICKLE_IMG
ARG YOSYS_IMG
ARG OPENROAD_IMG
ARG RISCV64_IMG
ARG VERILATOR_IMG
FROM ${PICKLE_IMG} as pickle
FROM ${YOSYS_IMG} as yosys
FROM ${OPENROAD_IMG} as openroad
FROM ${RISCV64_IMG} as riscv64
FROM ${VERILATOR_IMG} as verilator

FROM ${DOCKER_BASE_IMG} AS runner
# verible ships as a static release tarball; no dedicated builder stage
# (see design.md decision D4)
ARG VERIBLE_TAR=https://github.com/chipsalliance/verible/releases/download/v0.0-4148-g1ea007ec/verible-v0.0-4148-g1ea007ec-linux-static-x86_64.tar.gz
ENV DEBIAN_FRONTEND=noninteractive
# install packages
COPY packages.txt /packages.txt
RUN apt-get update && \
    apt-get install -y --no-install-recommends $(cat /packages.txt) && \
    rm -rf /var/lib/apt/lists/*
COPY requirements.txt /requirements.txt
RUN pip3 install --no-cache-dir --break-system-packages -r requirements.txt

# copy into runnner
COPY --from=pickle /build /build
COPY --from=yosys /build /build
COPY --from=openroad /build /build
COPY --from=riscv64 /build /build
COPY --from=verilator /build /build

RUN mkdir -p /build/bin && \
    curl -L ${VERIBLE_TAR} | tar -xzC /tmp --strip-components=1 && \
    cp /tmp/bin/verible-* /build/bin/ && \
    rm -rf /tmp/*

# gui
RUN dbus-uuidgen --ensure

ENV PATH /build/bin:$PATH
ENV LD_LIBRARY_PATH=/build/lib:$LD_LIBRARY_PATH
CMD /bin/bash
