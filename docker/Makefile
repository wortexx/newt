# Copyright (c) 2022 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Philippe Sauter <phsauter@ethz.ch>

# Directories
# directory of the path to the last called Makefile (this one)
DOCKER_DIR 		:= $(realpath $(dir $(realpath $(lastword $(MAKEFILE_LIST)))))

IMG_NAME = ghcr.io/wortexx/newt-eda
IMG_TAG = dev

# 2024 upstream image, kept reachable until the newt-eda adoption gate passes
# (docs/infra-plan.md Phase 1); flip back with `make pull-legacy`.
LEGACY_IMG_NAME = phsauter/pulp-iguana
LEGACY_IMG_TAG = dev

pull:
	docker pull $(IMG_NAME):$(IMG_TAG)

pull-legacy:
	docker pull $(LEGACY_IMG_NAME):$(LEGACY_IMG_TAG)

build: build-pickle build-yosys build-openroad build-riscv64 build-verilator
	cd $(DOCKER_DIR)/all && \
	docker build --build-arg PICKLE_IMG=newt-eda-pickle:$(IMG_TAG) \
				 --build-arg YOSYS_IMG=newt-eda-yosys:$(IMG_TAG) \
				 --build-arg OPENROAD_IMG=newt-eda-openroad:$(IMG_TAG) \
				 --build-arg RISCV64_IMG=newt-eda-riscv64:$(IMG_TAG) \
				 --build-arg VERILATOR_IMG=newt-eda-verilator:$(IMG_TAG) \
				 -t $(IMG_NAME):$(IMG_TAG) .


build-pickle:
	cd $(DOCKER_DIR)/pickle && \
	docker build -t newt-eda-pickle:$(IMG_TAG) .

build-yosys:
	cd $(DOCKER_DIR)/yosys && \
	docker build -t newt-eda-yosys:$(IMG_TAG) .

build-openroad:
	cd $(DOCKER_DIR)/openroad && \
	docker build -t newt-eda-openroad:$(IMG_TAG) .

build-riscv64:
	cd $(DOCKER_DIR)/riscv64 && \
	docker build -t newt-eda-riscv64:$(IMG_TAG) .

build-verilator:
	cd $(DOCKER_DIR)/verilator && \
	docker build -t newt-eda-verilator:$(IMG_TAG) .

.PHONY: pull pull-legacy build build-pickle build-yosys build-openroad build-riscv64 build-verilator
