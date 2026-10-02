# Copyright 2026 Kyiv School of Economics.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Convenience entry point: `make -C sw` builds the project programs through
# the top-level flow (rules live in sw.mk, included from iguana.mk).
all:
	$(MAKE) -C .. ig-sw-newt

clean:
	$(MAKE) -C .. ig-sw-newt-clean

.PHONY: all clean
