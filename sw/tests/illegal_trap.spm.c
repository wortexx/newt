// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Illegal-instruction trap regression for CV-X-IF enablement. With
// CvxifEn = 1, CVA6 no longer raises an illegal instruction at decode: it
// offloads the word to the coprocessor, and the trap comes from the
// coprocessor's reject path (cvxif_fu). The architectural result must be
// unchanged (spec keccak-coprocessor, "Genuinely illegal instruction still
// traps"): mcause = 2 and mtval = the faulting instruction bits (TvalEn = 1).
//
// Cases:
//   1. the all-zero word 0x00000000 - fetched as two 16-bit compressed
//      all-zero halfwords, each the canonical illegal instruction: 2 traps,
//      mtval = 0 each
//   2. 0x0000507B - custom-3 with funct3 = 101, claimed by no coprocessor
//      (the Keccak coprocessor accepts only custom-1): 1 trap,
//      mtval = 0x507B. This is the coprocessor's reject path.
//   3. 0x0000500B - custom-0. The pinned CVA6 decodes the whole custom-0
//      opcode as PULP's FENCE.T, so this must execute without trapping; the
//      test pins that fact down because the ISE's opcode choice depends on it.
// The trap handler steps mepc over the faulting instruction (2 or 4 bytes,
// from the instruction's low bits) so execution resumes after it.

#include "newt_test.h"

#define MAX_TRAPS 8

static volatile unsigned n_traps;
static volatile uint64_t trap_cause[MAX_TRAPS], trap_tval[MAX_TRAPS], trap_epc[MAX_TRAPS];
static volatile uint64_t trap_cycle[MAX_TRAPS];

// Overrides crt0's weak trap_vector; crt0's wrapper saves state and does mret.
void trap_vector(void) {
    uint64_t cause, tval, epc;
    asm volatile("csrr %0, mcause" : "=r"(cause));
    asm volatile("csrr %0, mtval" : "=r"(tval));
    asm volatile("csrr %0, mepc" : "=r"(epc));
    unsigned n = n_traps;
    if (n < MAX_TRAPS) {
        trap_cause[n] = cause;
        trap_tval[n] = tval;
        trap_epc[n] = epc;
        trap_cycle[n] = newt_csr_mcycle();
    }
    n_traps = n + 1;
    // Step over the faulting instruction: 16-bit if its low two bits are not 11.
    uint16_t lo = *(volatile uint16_t *)epc;
    uint64_t len = ((lo & 0x3) == 0x3) ? 4 : 2;
    asm volatile("csrw mepc, %0" ::"r"(epc + len));
}

int main(void) {
    newt_uart_init();
    printf("illegal_trap: start\r\n");

    uint64_t pc_zero, pc_custom3, t0, t1;

    // Case 1: all-zero word. `la` captures the address the trap must report.
    t0 = newt_csr_mcycle();
    asm volatile(
        "la %0, 1f\n"
        "1: .4byte 0x00000000\n"
        : "=r"(pc_zero)::"memory");
    t1 = newt_csr_mcycle();
    NEWT_CHECK(n_traps == 2, "zero word: %u traps, want 2", n_traps);
    for (unsigned i = 0; i < 2 && i < n_traps; i++) {
        NEWT_CHECK(trap_cause[i] == 2, "zero word trap %u: mcause %lu, want 2", i, trap_cause[i]);
        NEWT_CHECK(trap_tval[i] == 0, "zero word trap %u: mtval 0x%lx, want 0", i, trap_tval[i]);
        NEWT_CHECK(trap_epc[i] == pc_zero + 2 * i, "zero word trap %u: mepc 0x%lx, want 0x%lx", i,
                   trap_epc[i], pc_zero + 2 * i);
    }
    printf("illegal_trap: zero word, 2 traps in %lu cycles\r\n", t1 - t0);

    // Case 2: unclaimed custom-3 encoding (coprocessor reject path).
    unsigned base = n_traps;
    t0 = newt_csr_mcycle();
    asm volatile(
        "la %0, 1f\n"
        "1: .4byte 0x0000507B\n"
        : "=r"(pc_custom3)::"memory");
    t1 = newt_csr_mcycle();
    NEWT_CHECK(n_traps == base + 1, "custom-3: %u traps, want 1", n_traps - base);
    if (n_traps == base + 1) {
        NEWT_CHECK(trap_cause[base] == 2, "custom-3: mcause %lu, want 2", trap_cause[base]);
        NEWT_CHECK(trap_tval[base] == 0x507B, "custom-3: mtval 0x%lx, want 0x507b",
                   trap_tval[base]);
        NEWT_CHECK(trap_epc[base] == pc_custom3, "custom-3: mepc 0x%lx, want 0x%lx",
                   trap_epc[base], pc_custom3);
    }
    printf("illegal_trap: custom-3, %u trap(s) in %lu cycles\r\n", n_traps - base, t1 - t0);

    // Case 3: custom-0 is FENCE.T in this core: no trap.
    base = n_traps;
    asm volatile(".4byte 0x0000500B\n" ::: "memory");
    NEWT_CHECK(n_traps == base, "custom-0: %u traps, want 0 (FENCE.T)", n_traps - base);

    printf("illegal_trap: %s (%d failures)\r\n", newt_fails ? "FAIL" : "PASS", newt_fails);
    newt_uart_flush();
    return newt_exit_code(newt_fails);
}
