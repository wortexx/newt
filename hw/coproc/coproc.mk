# Copyright 2026 Kyiv School of Economics.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Description:
# Block-level unit tests for the Keccak coprocessor RTL in hw/coproc/.
# Each test is a Verilator model of one block (or a testbench-only wrapper of
# it) driven by a self-checking C++ harness in hw/coproc/tb/ against the
# independent C++ reference tb/keccak_ref.h. `make ig-coproc-unit` builds and
# runs every test and fails on the first one that reports a mismatch. This is
# the real body of the CI `sim-unit` check.

COPROC_DIR   := $(IG_ROOT)/hw/coproc
COPROC_TB    := $(COPROC_DIR)/tb
COPROC_BUILD := $(COPROC_DIR)/build

# CV-X-IF types come from CVA6's packages (cvxif_pkg -> ariane_pkg -> riscv).
COPROC_CVA6_DIR      = $(shell $(BENDER) path cva6)
COPROC_CC_DIR        = $(shell $(BENDER) path common_cells)
COPROC_CVA6_PKGS     = $(addprefix $(COPROC_CVA6_DIR)/core/include/, \
                         config_pkg.sv $(IG_CVA6_CONFIG)_config_pkg.sv riscv_pkg.sv \
                         ariane_pkg.sv cvxif_pkg.sv)
COPROC_KECCAK_SRCS   := $(COPROC_DIR)/keccak_pkg.sv $(COPROC_DIR)/keccak_round.sv

COPROC_VLT_FLAGS = --cc --exe --build -Wall -Wno-fatal -O2 --assert \
                   +incdir+$(COPROC_CC_DIR)/include \
                   -CFLAGS "-O2 -std=c++17 -I$(COPROC_TB)" -MAKEFLAGS "OBJCACHE="

# Supported kperm rounds-per-cycle values (divisors of 24, up to 6).
COPROC_ROUNDS_PER_CYCLE := 1 2 3 4 6

# Per test: TOP, SRCS, TB (C++ harness), FLAGS (extra Verilator flags).
COPROC_UNIT_TESTS := keccak_round $(foreach r,$(COPROC_ROUNDS_PER_CYCLE),keccak_cvxif_r$(r))

COPROC_TOP_keccak_round   := keccak_round
COPROC_SRCS_keccak_round   = $(COPROC_KECCAK_SRCS)
COPROC_TB_keccak_round    := $(COPROC_TB)/tb_keccak_round.cpp

define coproc_cvxif_test
COPROC_TOP_keccak_cvxif_r$(1)   := keccak_cvxif_tb_top
COPROC_SRCS_keccak_cvxif_r$(1)   = $$(COPROC_CVA6_PKGS) $$(COPROC_KECCAK_SRCS) \
                                   $(COPROC_DIR)/keccak_cvxif.sv $(COPROC_TB)/keccak_cvxif_tb_top.sv
COPROC_TB_keccak_cvxif_r$(1)    := $(COPROC_TB)/tb_keccak_cvxif.cpp
COPROC_FLAGS_keccak_cvxif_r$(1) := -GRoundsPerCycle=$(1) -CFLAGS -DROUNDS_PER_CYCLE=$(1)
endef
$(foreach r,$(COPROC_ROUNDS_PER_CYCLE),$(eval $(call coproc_cvxif_test,$(r))))

# One build rule per test: build/<test>/Vtb from its RTL and harness.
define coproc_unit_rule
$(COPROC_BUILD)/$(1)/Vtb: $$(COPROC_TB_$(1)) $(COPROC_TB)/keccak_ref.h $$(COPROC_SRCS_$(1))
	@mkdir -p $$(@D)
	$(VERILATOR) $(COPROC_VLT_FLAGS) $$(COPROC_FLAGS_$(1)) $$(COPROC_SRCS_$(1)) \
		--top-module $$(COPROC_TOP_$(1)) --Mdir $$(@D) -o Vtb $$(COPROC_TB_$(1))
endef
$(foreach t,$(COPROC_UNIT_TESTS),$(eval $(call coproc_unit_rule,$(t))))

.PHONY: ig-coproc-unit ig-coproc-clean
ig-coproc-unit: $(foreach t,$(COPROC_UNIT_TESTS),$(COPROC_BUILD)/$(t)/Vtb)
	@set -e; for t in $(COPROC_UNIT_TESTS); do \
		echo "== $$t"; $(COPROC_BUILD)/$$t/Vtb; \
	done

ig-coproc-clean:
	rm -rf $(COPROC_BUILD)
