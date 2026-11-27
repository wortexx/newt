# Copyright 2026 the newt project authors.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Chip finishing with KLayout (docs/infra-plan.md Phase 19). Stage A, change
# stream-final-gds: stream the routed DEF to GDS.
#
#   make gds                         # the flow's own openroad/out/basilisk.final.def
#   make gds GDS_DEF=/path/to/basilisk.final.def   # e.g. a P&R lane artifact
#
# Writes out/$(PROJ_NAME).gds.gz and out/$(PROJ_NAME).stream.log here. The IO
# pads stream empty: the pinned PDK has their LEF but no GDS (Phase 19 Stage C
# replaces them).

KLAYOUT ?= klayout

KLAYOUT_DIR     := $(realpath $(dir $(realpath $(lastword $(MAKEFILE_LIST)))))
TARGET_DIR      ?= $(realpath $(KLAYOUT_DIR)/..)
TOP_DESIGN      ?= iguana_chip
PROJ_NAME       ?= basilisk

GDS_DEF         ?= $(TARGET_DIR)/openroad/out/$(PROJ_NAME).final.def
GDS_OUT_DIR     ?= $(KLAYOUT_DIR)/out
GDS_OUT         := $(GDS_OUT_DIR)/$(PROJ_NAME).gds.gz
GDS_LOG         := $(GDS_OUT_DIR)/$(PROJ_NAME).stream.log

GDS_PDK_REF     := $(TARGET_DIR)/pdk/ihp-sg13g2/ihp-sg13g2/libs.ref
GDS_DLYLINE_DIR := $(TARGET_DIR)/src/mc_delay
GDS_SRAMS       := 64x64 256x48 256x64 512x64 1024x64 2048x64

# The LEFs the P&R flow reads (openroad/scripts/init_tech.tcl), so the DEF's
# cells resolve exactly as they did there - the delay line's .abst.lef included.
GDS_LEFS := \
	$(GDS_PDK_REF)/sg13g2_stdcell/lef/sg13g2_tech.lef \
	$(GDS_PDK_REF)/sg13g2_stdcell/lef/sg13g2_stdcell.lef \
	$(TARGET_DIR)/pdk/future/sg13g2_iocell/sg13g2_iocell.lef \
	$(foreach s,$(GDS_SRAMS),$(GDS_PDK_REF)/sg13g2_sram/lef/RM_IHPSG13_1P_$(s)_c2_bm_bist.lef) \
	$(GDS_DLYLINE_DIR)/delay_line_D4_O1_6P000.abst.lef

# Every placeable cell's geometry. All SRAM sizes: one the DEF does not use
# costs about a second and is dropped as an unused top cell.
GDS_GDS := \
	$(GDS_PDK_REF)/sg13g2_stdcell/gds/sg13g2_stdcell.gds \
	$(GDS_DLYLINE_DIR)/delay_line_D4_O1_6P000.gds \
	$(foreach s,$(GDS_SRAMS),$(GDS_PDK_REF)/sg13g2_sram/gds/RM_IHPSG13_1P_$(s)_c2_bm_bist.gds)

# Cells allowed to stream empty: the pre-release IO library's cells (every
# MACRO in sg13g2_iocell.lef), by exact name. Anything else empty fails.
GDS_IO_ALLOW := corner|filler1u|filler2u|filler4u|filler10u|gndcore|gndpad|vddcore|vddpad|ixc013_b16m|ixc013_b16mpdn|ixc013_b16mpup|ixc013_i16x|power_cut4u|power_cut60u

gds:
	@test -f "$(GDS_DEF)" || { echo "ERROR: DEF not found: $(GDS_DEF) (set GDS_DEF=...)" >&2; exit 1; }
	mkdir -p $(GDS_OUT_DIR)
	rm -f $(GDS_OUT)
	$(KLAYOUT) -b \
		-rd in_def="$(GDS_DEF)" \
		-rd lef_files="$(strip $(GDS_LEFS))" \
		-rd gds_files="$(strip $(GDS_GDS))" \
		-rd layer_map="$(KLAYOUT_DIR)/src/sg13g2.map" \
		-rd design_name="$(TOP_DESIGN)" \
		-rd io_allow="$(GDS_IO_ALLOW)" \
		-rd out_file="$(GDS_OUT)" \
		-r $(KLAYOUT_DIR)/scripts/def2stream.py \
		> $(GDS_LOG) 2>&1; \
	rc=$$?; cat $(GDS_LOG); exit $$rc

gds-clean:
	rm -f $(GDS_OUT) $(GDS_LOG)

.PHONY: gds gds-clean
