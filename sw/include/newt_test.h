// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Shared helpers for the project's bare-metal tests: UART bring-up, a
// printf-style reporter, and a CHECK macro that records the first failure.
// A test's `main` returns its exit code, which crt0 hands to the platform's
// end-of-computation register (the Xcelium lane's PASS/FAIL verdict).

#pragma once

#include <stdint.h>

#include "dif/clint.h"
#include "dif/uart.h"
#include "params.h"
#include "printf.h"
#include "regs/cheshire.h"
#include "util.h"

static inline void newt_uart_init(void) {
    uint32_t rtc_freq = *reg32(&__base_regs, CHESHIRE_RTC_FREQ_REG_OFFSET);
    uint64_t core_freq = clint_get_core_freq(rtc_freq, 2500);
    uart_init(&__base_uart, core_freq, __BOOT_BAUDRATE);
}

static inline void newt_uart_flush(void) { uart_write_flush(&__base_uart); }

// Number of failed checks so far.
static int newt_fails __attribute__((unused));

// Exit code for a test that saw `fails` failures: 0 for PASS, otherwise an
// EVEN code (2 * fails). An odd exit code hangs the JTAG-preload flow:
// crt0's _exit writes (code << 1) | 1 to SCRATCH[2] and returns into the
// bootrom's passive-boot loop, which takes SCRATCH[2] bit 1 as its "start"
// flag (cheshire_bootrom.c boot_passive), clears the register and jumps to
// a stale entry, so the testbench never sees the end-of-computation bit and
// reports TIMEOUT. See docs/infra-plan.md (Xcelium lane finding).
static inline int newt_exit_code(int fails) { return fails ? 2 * fails : 0; }

#define NEWT_CHECK(cond, ...)                                    \
    do {                                                         \
        if (!(cond)) {                                           \
            newt_fails++;                                        \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);          \
            printf(__VA_ARGS__);                                 \
            printf("\r\n");                                      \
        }                                                        \
    } while (0)

static inline uint64_t newt_csr_mcycle(void) {
    uint64_t v;
    asm volatile("csrr %0, mcycle" : "=r"(v)::"memory");
    return v;
}

static inline uint64_t newt_csr_minstret(void) {
    uint64_t v;
    asm volatile("csrr %0, minstret" : "=r"(v)::"memory");
    return v;
}
