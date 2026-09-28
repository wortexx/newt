# Copyright 2026 Kyiv School of Economics.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Description:
# Xcelium simulation lane for a restricted, offline VM. The host builds one
# self-contained bundle (sources, vendor models, ELFs, run script); the VM
# only needs `xrun`. See target/xcelium/README.md and
# openspec/changes/xcelium-sim-lane/ for the design rationale.

XRUN_DIR    := $(realpath $(dir $(realpath $(lastword $(MAKEFILE_LIST)))))
XRUN_BUILD  := $(XRUN_DIR)/build
XRUN_STAGE  := $(XRUN_BUILD)/bundle
XRUN_OUT    := $(XRUN_DIR)/out
XRUN_RAW_F  := $(XRUN_BUILD)/flist.raw.f

# The Questa lane's target set minus `hyper_test` (the hyperram vendor model,
# unused here: the DUT is iguana_soc with NO_HYPERBUS, same as Verilator).
# `simulation` brings in the IHP13 behavioral macros and Cheshire's vendor
# models; `test` brings in the VIP and riscv-dbg's jtag_test driver.
XRUN_BENDER_TARGETS := rtl simulation test $(BENDER_PROJ_TARGETS)
XRUN_BENDER_DEFINES := FUNCTIONAL NO_HYPERBUS

# Files the `simulation`/`test` targets pull in that this lane must not compile
# (paths are bundle-relative):
# - The Questa full-chip fixture: instantiates iguana_chip and hyperram.
# - Second definitions of `sram` and `configurable_delay`. Questa lets the last
#   one compiled win; excluding the extra copies keeps exactly the definitions
#   the Verilator lane and synthesis use (sram_pulp.sv, target/ihp13 mc_delay).
# - Standalone dependency testbenches that never elaborate here and that fail
#   a strict (slang) parse, so they cannot cost a VM round trip.
XRUN_EXCLUDE_PATTERN := ^target/sim/src/(fixture|tb)_iguana\.sv$$
XRUN_EXCLUDE_PATTERN := $(XRUN_EXCLUDE_PATTERN)|/common_cells-[^/]*/src/deprecated/sram\.sv$$
XRUN_EXCLUDE_PATTERN := $(XRUN_EXCLUDE_PATTERN)|/hyperbus-[^/]*/models/configurable_delay\.behav\.sv$$
XRUN_EXCLUDE_PATTERN := $(XRUN_EXCLUDE_PATTERN)|/apb-[^/]*/test/tb_apb_cdc\.sv$$
XRUN_EXCLUDE_PATTERN := $(XRUN_EXCLUDE_PATTERN)|/common_cells-[^/]*/test/cdc_(fifo|2phase)_tb\.sv$$
XRUN_EXCLUDE_PATTERN := $(XRUN_EXCLUDE_PATTERN)|/riscv-dbg-[^/]*/tb/jtag_dmi/tb_jtag_dmi\.sv$$

XRUN_VENDOR_MODELS := \
  $(CHS_ROOT)/target/sim/models/s25fs512s.v \
  $(CHS_ROOT)/target/sim/models/24FC1025.v

XRUN_TB_SRCS := \
  $(XRUN_DIR)/src/fixture_newt_xrun.sv \
  $(XRUN_DIR)/src/tb_newt_xrun.sv

XRUN_DPI_SRCS := $(CHS_ROOT)/target/sim/src/elfloader.cpp

# SPM-linked tests only: the DUT has no DRAM behind the LLC.
XRUN_ELFS ?= $(wildcard $(CHS_ROOT)/sw/tests/*.spm.elf)

$(XRUN_RAW_F): Bender.yml Bender.lock $(XRUN_VENDOR_MODELS)
	@mkdir -p $(@D)
	$(BENDER) script flist-plus --no-default-target \
		$(foreach d,$(XRUN_BENDER_DEFINES),-D $(d)) \
		$(foreach t,$(XRUN_BENDER_TARGETS),-t $(t)) > $@.tmp
	mv $@.tmp $@

.PHONY: ig-xrun-stage ig-xrun-bundle ig-sim-xrun

ig-xrun-stage: $(XRUN_RAW_F) $(XRUN_TB_SRCS) $(XRUN_DPI_SRCS)
	IG_ROOT='$(IG_ROOT)' STAGE='$(XRUN_STAGE)' RAW_FLIST='$(XRUN_RAW_F)' \
	EXCLUDE_PATTERN='$(XRUN_EXCLUDE_PATTERN)' \
	EXTRA_SRCS='$(XRUN_TB_SRCS) $(XRUN_DPI_SRCS)' \
	ELFS='$(XRUN_ELFS)' BENDER='$(BENDER)' LANE_DIR='$(XRUN_DIR)' \
		bash $(XRUN_DIR)/scripts/stage.sh

ig-xrun-bundle: ig-xrun-stage
	@mkdir -p $(XRUN_OUT)
	bash $(XRUN_DIR)/scripts/pack.sh $(XRUN_STAGE) $(XRUN_OUT)

# Runs the exact VM procedure in place, for machines that have `xrun`.
# BINARY/BOOTMODE/PRELMODE are shared with (and defaulted by) verilator.mk;
# `BINARY=` (empty) runs every bundled ELF.
ig-sim-xrun: ig-xrun-stage
	cd $(XRUN_STAGE) && BOOTMODE=$(BOOTMODE) PRELMODE=$(PRELMODE) \
		./run.sh $(notdir $(BINARY))
