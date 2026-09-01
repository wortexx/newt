# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Description:
# Open-source (Questa-free) simulation lane: builds a Verilator model of the
# digital SoC (iguana_soc, compiled with -D NO_HYPERBUS) and runs it against
# prebuilt riscv test binaries. See openspec/changes/verilator-sim-flow/ for
# the design rationale, in particular why the Bender target set here differs
# from the Questa flow's BENDER_SIM_TARGETS.

VERILATOR      ?= verilator
VERILATOR_DIR  := $(realpath $(dir $(realpath $(lastword $(MAKEFILE_LIST)))))
VERILATOR_BUILD:= $(VERILATOR_DIR)/build
VERILATOR_OBJ  := $(VERILATOR_DIR)/obj_dir
VERILATOR_TOP  := newt_verilator_top

# Bender target set for the Verilator lane: RTL + IHP13 tech wrappers, no
# `simulation`/`test` targets. Those targets also gate Cheshire's own vendor
# sim models (SPI flash / I2C EEPROM used by vip_cheshire_soc, fetched from
# an external, partially non-free source) which this DUT does not instantiate
# and does not want to depend on. Reuses BENDER_SYNTH_TARGETS (rtl + project
# targets) already defined by iguana.mk.
VERILATOR_BENDER_TARGETS := $(BENDER_SYNTH_TARGETS)

# The functional (behavioral) models for the IHP13 SRAM/stdcell/pad macros
# that target/ihp13/src/tc_sram.sv unconditionally instantiates. Normally
# reached via Bender's `all(ihp13, simulation)` target, but pulled in here as
# a fixed, hand-picked file list (see VERILATOR_BENDER_TARGETS note above)
# instead of via `-t simulation`. Keep this list in sync with the
# `all(ihp13, simulation)` block in Bender.yml if that block ever changes.
VERILATOR_IHP13_SIM_MODELS := \
  $(IG_ROOT)/target/ihp13/src/mc_delay/delay_line_D4_O1_6P000.behav.sv \
  $(IG_ROOT)/target/ihp13/pdk/ihp-sg13g2/ihp-sg13g2/libs.ref/sg13g2_stdcell/verilog/sg13g2_stdcell.v \
  $(IG_ROOT)/target/ihp13/pdk/ihp-sg13g2/ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_core_behavioral_bm_bist.v \
  $(IG_ROOT)/target/ihp13/pdk/ihp-sg13g2/ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_64x64_c2_bm_bist.v \
  $(IG_ROOT)/target/ihp13/pdk/ihp-sg13g2/ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_256x48_c2_bm_bist.v \
  $(IG_ROOT)/target/ihp13/pdk/ihp-sg13g2/ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_256x64_c2_bm_bist.v \
  $(IG_ROOT)/target/ihp13/pdk/ihp-sg13g2/ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_512x64_c2_bm_bist.v \
  $(IG_ROOT)/target/ihp13/pdk/ihp-sg13g2/ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_1024x64_c2_bm_bist.v \
  $(IG_ROOT)/target/ihp13/pdk/ihp-sg13g2/ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_2048x64_c2_bm_bist.v \
  $(IG_ROOT)/target/ihp13/pdk/future/sg13g2_iocell/sg13g2_iocell.behav.sv

VERILATOR_FLIST := $(VERILATOR_BUILD)/flist.verilator.f

# Files pulled in by Bender's default (untargeted) source lists that this
# design never instantiates and that Verilator cannot parse at all - not a
# lint waiver (nothing here is elaborated), just excluded from the file list.
# `tech_cells_generic`'s deprecated `pad_functional.sv` uses Verilog-1995
# gate primitives (`rpmos`); this project's own IHP13 pad wrapper
# (target/ihp13/src/mc_pad.sv) is used instead, and pad_functional's module
# is confirmed unreferenced anywhere in this design's hierarchy.
VERILATOR_EXCLUDE_PATTERN := tech_cells_generic-[^/]*/src/deprecated/pad_functional\.sv$$

# `FUNCTIONAL` matches the guard the IHP13 SRAM/pad behavioral models use to
# enable their simulation-only bodies (mirrors the `all(ihp13, simulation)`
# Bender.yml block); `NO_HYPERBUS` takes iguana_soc's own escape hatch to tie
# off the hyperbus controller instead of instantiating it (see design.md D1 -
# this DUT does not exercise hyperbus/DRAM). Deliberately no explicit
# `VERILATOR` define: Verilator predefines it itself, and redefining it here
# only produces a harmless-but-noisy REDEFMACRO warning. Deliberately no
# `SYNTHESIS` define either: several common_cells files gate simulation-only
# checks on `` `ifndef SYNTHESIS `` and must stay active for a functional sim.
$(VERILATOR_FLIST): Bender.yml Bender.lock $(VERILATOR_DIR)/src/$(VERILATOR_TOP).sv $(VERILATOR_DIR)/verilator.vlt
	@mkdir -p $(@D)
	@echo '$(VERILATOR_DIR)/verilator.vlt' > $@
	$(BENDER) script verilator --no-default-target -D FUNCTIONAL -D NO_HYPERBUS \
		$(foreach t,$(VERILATOR_BENDER_TARGETS),-t $(t)) \
		| grep -Ev '$(VERILATOR_EXCLUDE_PATTERN)' >> $@
	@for f in $(VERILATOR_IHP13_SIM_MODELS); do echo "$$f" >> $@; done
	@echo '$(VERILATOR_DIR)/src/$(VERILATOR_TOP).sv' >> $@

.PHONY: ig-verilator-flist
ig-verilator-flist: $(VERILATOR_FLIST)

VERILATOR_TB_SRCS := $(VERILATOR_DIR)/src/newt_tb.cpp
VERILATOR_MODEL   := $(VERILATOR_OBJ)/V$(VERILATOR_TOP)

# `--timing` tolerates the `#delay`s in the IHP13 behavioral tech models
# without needing sed-level RTL surgery (see design.md D3). `-Wno-fatal`
# only changes whether *warnings* affect exit status - genuine `%Error`-class
# issues (like the one this file's verilator.vlt waives) stay fatal. Left
# unwaived: ~29 UNOPTFLAT warnings in common_cells' CDC 4-phase handshake
# logic - the canonical, functionally-harmless Verilator warning for
# intentional CDC synchronizer feedback loops (see design.md Risks).
# `OBJCACHE=` disables Verilator's generated Makefile default of shelling
# out to `ccache`, which the newt-eda image does not have (found the same
# way the gawk/unzip gap was in Phase 1: the tool the flow silently depends
# on, not one the smoke test or Verilator's own presence check caught) -
# this overrides it rather than adding a build-only tool to the image.
$(VERILATOR_MODEL): $(VERILATOR_FLIST) $(VERILATOR_TB_SRCS)
	$(VERILATOR) --cc --exe --build --timing -Wno-fatal \
		-f $(VERILATOR_FLIST) --top-module $(VERILATOR_TOP) \
		--Mdir $(VERILATOR_OBJ) -o V$(VERILATOR_TOP) \
		-CFLAGS "-O2" -MAKEFLAGS "OBJCACHE=" \
		$(VERILATOR_TB_SRCS)

.PHONY: ig-verilator-model
ig-verilator-model: $(VERILATOR_MODEL)

# Run configuration, overridable from the command line, e.g.:
#   make ig-sim-verilator BINARY=sw/tests/other.spm.elf
# Mirrors the Questa flow's SIM_PRE_COMPILE defaults (BOOTMODE 0 / PRELMODE 0
# / helloworld.spm.elf), but as plain Make variables instead of a Tcl string
# that has to be hand-edited to switch modes.
BINARY          ?= $(CHS_ROOT)/sw/tests/helloworld.spm.elf
BOOTMODE        ?= 0
PRELMODE        ?= 0
TIMEOUT_CYCLES  ?= 20000000

.PHONY: ig-sim-verilator
ig-sim-verilator: $(VERILATOR_MODEL)
	$(VERILATOR_MODEL) +BINARY=$(BINARY) +BOOTMODE=$(BOOTMODE) +PRELMODE=$(PRELMODE) \
		+TIMEOUT_CYCLES=$(TIMEOUT_CYCLES)
