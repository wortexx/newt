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

# Project library (sw/lib/*.c): archived like libcheshire (same archiver and
# LTO plugin flags) and linked into every project program ahead of it.
NEWT_SW_LIB_SRCS := $(wildcard $(NEWT_SW_DIR)/lib/*.c)
NEWT_SW_LIB      := $(NEWT_SW_DIR)/lib/libnewt.a

$(NEWT_SW_LIB): $(NEWT_SW_LIB_SRCS:.c=.o)
	rm -f $@
	$(CHS_SW_AR) $(CHS_SW_ARFLAGS) -rcsv $@ $^

# Project headers only for project objects; Cheshire's own tests are unaffected.
$(NEWT_SW_DIR)/%.o: CHS_SW_INCLUDES += -I$(NEWT_SW_DIR)/include -I$(NEWT_SW_DIR)/vectors

# Cheshire's link rule links `$*.o $(CHS_SW_LIBS)`; for project programs the
# library list is prefixed with libnewt (prerequisite stated explicitly, as a
# target-specific value does not reach the rule's prerequisite list).
$(NEWT_SW_TESTS): $(NEWT_SW_LIB)
$(NEWT_SW_TESTS): CHS_SW_LIBS := $(NEWT_SW_LIB) $(CHS_SW_LIBS)

# Build provenance for the evaluation (scripts/sha3_eval.py): Cheshire's link
# scripts drop .comment, so the ELFs cannot name their compiler themselves.
NEWT_SW_BUILD_INFO := $(NEWT_SW_DIR)/tests/BUILD_INFO
$(NEWT_SW_BUILD_INFO): $(NEWT_SW_TESTS)
	{ echo "compiler: $$($(CHS_SW_CC) --version | head -1)"; \
	  echo "flags:    $(CHS_SW_FLAGS)"; } > $@

.PHONY: ig-sw-newt ig-sw-newt-clean
ig-sw-newt: $(NEWT_SW_TESTS) $(NEWT_SW_DUMPS) $(NEWT_SW_BUILD_INFO)

ig-sw-newt-clean:
	rm -f $(NEWT_SW_DIR)/tests/*.o $(NEWT_SW_DIR)/tests/*.elf $(NEWT_SW_DIR)/tests/*.dump \
		$(NEWT_SW_DIR)/lib/*.o $(NEWT_SW_LIB) $(NEWT_SW_BUILD_INFO)

ig-sw-all: ig-sw-newt
