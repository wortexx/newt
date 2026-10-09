# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Tools
OPENROAD 		?= openroad

# Directories
# directory of the path to the last called Makefile (this one)
OPENROAD_DIR    := $(realpath $(dir $(realpath $(lastword $(MAKEFILE_LIST)))))
IG_ROOT		    ?= $(realpath $(OPENROAD_DIR)/../../..)
TARGET_DIR		?= $(realpath $(OPENROAD_DIR)/..)

# Project variables
# if you are running the entire flow these are set by iguana.mk
# in that case do not change them here
TOP_DESIGN 	?= iguana_chip
PROJ_NAME	?= $(TOP_DESIGN)
NETLIST		?= $(TARGET_DIR)/yosys/out/$(PROJ_NAME).yosys.v
# emtpy if the netlist includes hyperbus, otherwise HYPER_CONF=NO_HYPERBUS
HYPER_CONF	 ?= 
L1CACHE_WAYS ?=

OPENROAD_OUT_DIR	?= $(OPENROAD_DIR)
SAVE				?= $(OPENROAD_OUT_DIR)/save
REPORTS				?= $(OPENROAD_OUT_DIR)/reports
LOG_PATH			:= "$(OPENROAD_OUT_DIR)/$(PROJ_NAME)_$(shell date +"%Y-%m-%d_%H_%M_%Z").log"

###########
# Patches #
###########

# Patch to the vendored PDK's checked-out content, applied fresh before
# every backend run (matches the existing rtl-patches pattern in
# ../pickle/pickle.mk, which post-patches CVA6's ariane_pkg.sv the same
# way - established project convention for a vendored dependency, not
# something new). Every SRAM macro's A_DOUT output bus declares
# `max_capacitance : "6.4e-14"` - as picofarads (this library's own
# capacitive_load_unit), 14 orders of magnitude too small (a min buffer's
# own input cap is ~0.001pF) - which trips OpenROAD 2c56926's resizer
# (RSZ-0169) during repair_design/repair_timing (found via
# openspec/changes/ci-pnr-lane task 2.4's real bring-up). Confirmed a
# genuine PDK content bug, not a flow issue: a newer upstream PDK release
# has the same field reading 0.064 (physically sensible; matches a
# units-scale bug in our pinned commit exactly: 6.4e-14 Farads == 0.064
# picofarads). No Tcl/SDC-level override exists for this - OpenSTA's
# set_max_capacitance only accepts design-level pins, and the SWIG-bound
# LibertyPort object exposes no capacitance-limit setter at all - so this
# is patched directly in the checked-out file, idempotent (sed is a no-op
# once already patched) and never committed to the PDK's own git history.
define pdk-patches
	sed -i 's/max_capacitance  : "6.4e-14" ;/max_capacitance  : 0.064 ;/' \
		$(TARGET_DIR)/pdk/ihp-sg13g2/ihp-sg13g2/libs.ref/sg13g2_sram/lib/RM_IHPSG13_1P_*_c2_bm_bist_*.lib
endef

backend-all: run-openroad

run-openroad:
	mkdir -p $(SAVE)
	mkdir -p $(REPORTS)
	$(call pdk-patches,)
	$(MAKE) or-run-snapshot
	cd $(OPENROAD_DIR) && ln -fs $(LOG_PATH) $(PROJ_NAME).log
	cd $(OPENROAD_DIR) && \
	NETLIST="$(NETLIST)" \
	TOP_DESIGN="$(TOP_DESIGN)" \
	PROJ_NAME="$(PROJ_NAME)" \
	SAVE="$(SAVE)" \
	REPORTS="$(REPORTS)" \
	HYPER_CONF="$(HYPER_CONF)" \
	L1CACHE_WAYS="$(L1CACHE_WAYS)" \
	PDK="$(TARGET_DIR)/pdk" \
	$(OPENROAD) scripts/chip.tcl -gui \
		-log $(LOG_PATH) \
		2>&1 | TZ=UTC gawk '{ print strftime("[%Y-%m-%d %H:%M %Z]"), $$0 }';

or-run-snapshot:
	zip -r $(SAVE)/$(PROJ_NAME)_source.zip \
		    $(subst $(IG_ROOT)/,,$(IG_ROOT)/iguana.mk) \
	        $(subst $(IG_ROOT)/,,$(NETLIST)) \
	        $(subst $(IG_ROOT)/,,$(YOSYS_DIR)/scripts) \
	        $(subst $(IG_ROOT)/,,$(YOSYS_DIR)/*.mk) \
	        $(subst $(IG_ROOT)/,,$(YOSYS_REPORTS)/$(RTL_NAME)*) \
	        $(subst $(IG_ROOT)/,,$(PICKLE_OUT)/$(RTL_NAME).*) \
	        $(subst $(IG_ROOT)/,,$(OPENROAD_DIR)/openroad.mk) \
	        $(subst $(IG_ROOT)/,,$(OPENROAD_DIR)/scripts)

# Unattended, resumable P&R flow for CI (docs/infra-plan.md Phase 5;
# openspec/changes/ci-pnr-lane/design.md D1) - one openroad -exit process
# per stage (scripts/pnr/*.tcl), driven by run_pnr.sh, instead of
# run-openroad's single long-lived -gui session. Exits 0 iff every stage
# through PNR_GATE (default: grt, i.e. global route - see specs/pnr-flow)
# completed; see run_pnr.sh's own header for every env var it reads
# (PNR_GATE, PNR_SKIP_GRT_REPAIR, PNR_DRT_END_ITER, PNR_STAGE_TIMEOUT,
# PNR_TIMEOUT_<STAGE>, PNR_DRY_RUN).
run-pnr:
	mkdir -p $(SAVE)
	mkdir -p $(REPORTS)
	$(call pdk-patches,)
	cd $(OPENROAD_DIR) && \
	NETLIST="$(NETLIST)" \
	TOP_DESIGN="$(TOP_DESIGN)" \
	PROJ_NAME="$(PROJ_NAME)" \
	SAVE="$(SAVE)" \
	REPORTS="$(REPORTS)" \
	HYPER_CONF="$(HYPER_CONF)" \
	L1CACHE_WAYS="$(L1CACHE_WAYS)" \
	PDK="$(TARGET_DIR)/pdk" \
	./run_pnr.sh

# SoC power probe on a synthesized netlist (docs/infra-plan.md Phase 17;
# openspec/changes/pin-soc-power-activity design D2). No placement and no
# VM: any synth-lane netlist works, e.g.
#   gh run download <synth run> -n basilisk-netlist -D /tmp/nl/<label>
#   make soc-power-probe NETLIST=/tmp/nl/<label>/basilisk.yosys.v
# Output in $(OPENROAD_DIR)/out/power-probe/<label>/ (git-ignored): probe.log,
# soc_power_probe.rpt (the lane's report_metrics, uniform activity) and
# inst.txt (~100 MB, per-instance power), then a per-module table from
# scripts/soc_power_agg.py. About 25 min per netlist under amd64 emulation
# on an M3 Max. The default-activity power it prints first is a diagnostic,
# not a power figure: on this SoC OpenSTA's propagation stops at its 50-pass
# cap without converging (see the `power_activity: Pass` lines).
SOC_POWER_OUT ?= $(OPENROAD_DIR)/out/power-probe/$(notdir $(patsubst %/,%,$(dir $(NETLIST))))

soc-power-probe:
	mkdir -p $(SOC_POWER_OUT)
	cd $(OPENROAD_DIR) && \
	NETLIST="$(NETLIST)" \
	OUT="$(SOC_POWER_OUT)" \
	PDK="$(TARGET_DIR)/pdk" \
	$(OPENROAD) -no_init -no_splash -exit -log $(SOC_POWER_OUT)/probe.log \
		scripts/soc_power_probe.tcl
	python3 $(IG_ROOT)/scripts/soc_power_agg.py $(SOC_POWER_OUT)/inst.txt

PHONY: run-openroad backend-all or-run-snapshot run-pnr soc-power-probe