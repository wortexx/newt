# Copyright 2026 Kyiv School of Economics.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Description:
# Project-local bare-metal programs (tests and benchmarks for the Keccak
# coprocessor work). They are built with Cheshire's own toolchain variables,
# flags, runtime (libcheshire, crt0) and linker scripts: the pattern rules in
# Cheshire's sw.mk (included via cheshire.mk) do the compiling and linking, so
# a newt program builds exactly like a Cheshire test. Only SPM-linked programs
# (`*.spm.c`) are built: the simulated DUT has no DRAM behind the LLC.

NEWT_SW_DIR   := $(IG_ROOT)/sw
NEWT_SW_SRCS  := $(wildcard $(NEWT_SW_DIR)/tests/*.spm.c)
NEWT_SW_TESTS := $(NEWT_SW_SRCS:.c=.elf)
NEWT_SW_DUMPS := $(NEWT_SW_SRCS:.c=.dump)

# Project headers only for project programs; Cheshire's own tests are unaffected.
$(NEWT_SW_DIR)/%.o: CHS_SW_INCLUDES += -I$(NEWT_SW_DIR)/include

.PHONY: ig-sw-newt ig-sw-newt-clean
ig-sw-newt: $(NEWT_SW_TESTS) $(NEWT_SW_DUMPS)

ig-sw-newt-clean:
	rm -f $(NEWT_SW_DIR)/tests/*.o $(NEWT_SW_DIR)/tests/*.elf $(NEWT_SW_DIR)/tests/*.dump

ig-sw-all: ig-sw-newt
