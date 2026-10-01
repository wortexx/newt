// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// SHA-3 cycle and instruction benchmark (spec sha3-evaluation, "Cycle and
// instruction counts from RTL simulation"). For every variant and every
// implementation (both ISE back-ends and the three software baselines) it
// hashes messages of 0, 1, 2 and 4 full rate blocks (1, 2, 3 and 5
// permutations including the padding block) and reads mcycle/minstret
// around the hash call, minus the measured cost of the counter reads.
//
// Each (variant, implementation) is run once untimed first so the
// instruction cache is warm; the reported numbers are steady-state.
// Interrupts are disabled throughout (design D5).
//
// Output (parsed by scripts/sha3_eval.py), one line per variant x impl to
// keep UART time down (each character costs ~87 us of simulated time):
//   CALIB,<cycles>,<instret>
//   RESULT,<variant>,<impl>,<rate>,<bytes>:<cycles>:<instret>,...
// <variant> is the digest size (224/256/384/512), <impl> the sha3_impl_name().

#include "newt_test.h"
#include "sha3.h"

static const unsigned kBlocks[] = {0, 1, 2, 4};
#define NUM_LENGTHS (sizeof(kBlocks) / sizeof(kBlocks[0]))
#define MAX_MSG (4 * 144)

static uint8_t msg[MAX_MSG];

typedef struct {
    uint64_t cycles, instret;
} counts_t;

// The measured region: counter reads around one call. noinline keeps the
// region identical for every implementation and for the calibration.
static __attribute__((noinline)) counts_t measure(sha3_variant_t v, sha3_impl_t impl,
                                                  const uint8_t *m, size_t len, uint8_t *out,
                                                  int empty) {
    uint64_t c0, i0, c1, i1;
    asm volatile("csrr %0, mcycle\n csrr %1, minstret" : "=r"(c0), "=r"(i0)::"memory");
    if (!empty) sha3_hash(v, impl, m, len, out);
    asm volatile("csrr %0, mcycle\n csrr %1, minstret" : "=r"(c1), "=r"(i1)::"memory");
    counts_t r = {c1 - c0, i1 - i0};
    return r;
}

int main(void) {
    newt_uart_init();
    set_mie(0);
    for (unsigned k = 0; k < MAX_MSG; k++) msg[k] = (uint8_t)(31 * k + 7);

    // Counter-read overhead: minimum over a few empty measurements.
    counts_t calib = {~0ull, ~0ull};
    for (unsigned n = 0; n < 8; n++) {
        counts_t e = measure(SHA3_256, SHA3_IMPL_ISE_KPERM, msg, 0, 0, 1);
        if (e.cycles < calib.cycles) calib = e;
    }
    printf("CALIB,%lu,%lu\r\n", calib.cycles, calib.instret);

    uint8_t out[64];
    for (unsigned v = 0; v < SHA3_NUM_VARIANTS; v++) {
        unsigned rate = sha3_rate_bytes((sha3_variant_t)v);
        for (unsigned impl = 0; impl < SHA3_NUM_IMPLS; impl++) {
            counts_t res[NUM_LENGTHS];
            measure((sha3_variant_t)v, (sha3_impl_t)impl, msg, rate, out, 0);  // warm-up
            for (unsigned l = 0; l < NUM_LENGTHS; l++) {
                counts_t c =
                    measure((sha3_variant_t)v, (sha3_impl_t)impl, msg, kBlocks[l] * rate, out, 0);
                res[l].cycles = c.cycles - calib.cycles;
                res[l].instret = c.instret - calib.instret;
            }
            printf("RESULT,%u,%s,%u", 8 * sha3_digest_bytes((sha3_variant_t)v),
                   sha3_impl_name((sha3_impl_t)impl), rate);
            for (unsigned l = 0; l < NUM_LENGTHS; l++)
                printf(",%u:%lu:%lu", kBlocks[l] * rate, res[l].cycles, res[l].instret);
            printf("\r\n");
        }
    }
    printf("sha3_bench: DONE\r\n");
    newt_uart_flush();
    return 0;
}
