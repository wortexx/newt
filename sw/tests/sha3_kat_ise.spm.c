// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Known-answer test for the Keccak ISE (spec sha3-evaluation, "Known-answer
// correctness gate"): every vector of sw/vectors/sha3_kat_vectors.h through
// both coprocessor back-ends (kperm and 24 x shatr), interrupts disabled
// (design D5 operating constraint). Exits non-zero on the first mismatch,
// naming variant, implementation and vector.
//
// Also the directed check of spec keccak-coprocessor, "Non-writing
// instruction with a non-zero rd is illegal": kxor encoded with rd = x5
// must trap (mcause 2), leave the Keccak state unchanged, and leave x5
// intact for the very next instruction, which reads it.

#include "keccak_ise.h"
#include "newt_test.h"
#include "sha3.h"
#include "sha3_kat_vectors.h"

static volatile unsigned n_traps;
static volatile uint64_t last_cause;

// Overrides crt0's weak trap_vector: record, then step over the instruction.
void trap_vector(void) {
    uint64_t cause, epc;
    asm volatile("csrr %0, mcause" : "=r"(cause));
    asm volatile("csrr %0, mepc" : "=r"(epc));
    last_cause = cause;
    n_traps = n_traps + 1;
    uint16_t lo = *(volatile uint16_t *)epc;
    asm volatile("csrw mepc, %0" ::"r"(epc + (((lo & 0x3) == 0x3) ? 4 : 2)));
}

static int check_rd_nonzero_rejected(void) {
    const uint64_t sentinel = 0x5A5A1234C0FFEE00ull;
    const uint64_t lane_value = 0x0123456789ABCDEFull;
    keccak_kclr();
    keccak_kxor(lane_value, 3);

    unsigned base = n_traps;
    uint64_t seen;
    // kxor (funct3 = 1) encoded with rd = x5 (t0), which must be rejected.
    // t0 holds the sentinel; the `mv` reads t0 in the very next instruction
    // (the window in which the pinned CVA6 forwards offload results).
    asm volatile(
        "mv t0, %1\n"
        ".insn r 0x2B, 1, 0, t0, %2, %3\n"
        "mv %0, t0\n"
        : "=r"(seen)
        : "r"(sentinel), "r"(~0ull), "r"(3ull)
        : "t0", "memory");

    int fails = 0;
    if (n_traps - base != 1) {
        printf("FAIL rd!=x0: %u traps, want 1\r\n", n_traps - base);
        fails++;
    }
    if (last_cause != 2) {
        printf("FAIL rd!=x0: mcause %lu, want 2\r\n", last_cause);
        fails++;
    }
    if (seen != sentinel) {
        printf("FAIL rd!=x0: dependent reader saw 0x%lx, want 0x%lx\r\n", seen, sentinel);
        fails++;
    }
    uint64_t lane = keccak_krd(3);
    if (lane != lane_value) {
        printf("FAIL rd!=x0: lane 3 = 0x%lx, want 0x%lx (state changed)\r\n", lane, lane_value);
        fails++;
    }
    return fails;
}

int main(void) {
    newt_uart_init();
    set_mie(0);
    printf("sha3_kat_ise: %u vectors x %u implementations\r\n", SHA3_NUM_KATS,
           (unsigned)(SHA3_FIRST_SW - SHA3_FIRST_ISE));

    for (unsigned k = 0; k < SHA3_NUM_KATS; k++) {
        const sha3_kat_t *t = &sha3_kats[k];
        unsigned n = sha3_digest_bytes(t->variant);
        for (unsigned impl = SHA3_FIRST_ISE; impl < SHA3_FIRST_SW; impl++) {
            uint8_t d[64];
            sha3_hash(t->variant, (sha3_impl_t)impl, t->msg, t->len, d);
            uint8_t want_first = t->md[0];
#ifdef SHA3_KAT_CORRUPT_VECTOR
            // One-off negative test build: expect a wrong digest for one vector.
            if (k == SHA3_KAT_CORRUPT_VECTOR) want_first ^= 0x01;
#endif
            int ok = (d[0] == want_first);
            for (unsigned b = 1; b < n; b++) ok &= (d[b] == t->md[b]);
            if (!ok) {
                printf("FAIL %s %s vector %u (len %u): digest mismatch\r\n",
                       sha3_variant_name(t->variant), sha3_impl_name((sha3_impl_t)impl), k,
                       (unsigned)t->len);
                newt_uart_flush();
                return 1;
            }
        }
    }
    printf("sha3_kat_ise: all %u vectors pass on both implementations\r\n", SHA3_NUM_KATS);

    int fails = check_rd_nonzero_rejected();
    printf("sha3_kat_ise: %s (%d failures)\r\n", fails ? "FAIL" : "PASS", fails);
    newt_uart_flush();
    return fails;
}
