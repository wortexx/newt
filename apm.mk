# Copyright 2026 the newt project authors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Bootstraps the apm-managed Claude Code agents/skills/rules declared in
# apm.yml (pinned in apm.lock.yaml). These are regenerable, upstream-sourced
# content and are gitignored - `make apm` is how you get them locally.
# openspec/changes/apm-makefile-bootstrap/design.md D1/D2.

.PHONY: apm

apm:
	@command -v apm >/dev/null 2>&1 || { \
		echo "error: 'apm' CLI not found on PATH."; \
		echo "  Install it, e.g. 'brew install apm' (https://microsoft.github.io/apm/), then re-run 'make apm'."; \
		exit 1; \
	}
	apm install
