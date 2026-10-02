// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// SHA-3 cycle and instruction benchmark (spec sha3-evaluation, "Cycle and
// instruction counts from RTL simulation"). For every variant and every
// implementation (both ISE back-ends and the three software baselines; for
// SHA3-256 also the MMIO accelerator, CPU- and DMA-fed, for the crossover of
// task 7.1) it hashes messages of 0, 1, 2 and 4 full rate blocks (1, 2, 3 and 5
// permutations including the padding block) and reads mcycle/minstret
// around the hash call, minus the measured cost of the counter reads.
//
// Each (variant, implementation) is run once untimed first, on the longest
// message, so the instruction and data caches are warm; the reported numbers
// are steady-state.
// Interrupts are disabled throughout (design D5).
//
// Every timed hash is also checked: its digest must equal the software XKCP
// opt64 digest of the same message, computed untimed. A mismatch prints a
// MISMATCH line and fails the test, so a broken back-end cannot report timings.
//
// Output (parsed by scripts/sha3_eval.py), one line per variant x impl to
// keep UART time down (each character costs ~87 us of simulated time):
//   CALIB,<cycles>,<instret>
//   RESULT,<variant>,<impl>,<rate>,<bytes>:<cycles>:<instret>,...
//   MISMATCH,<variant>,<impl>,<bytes>      (only on a wrong digest)
// <variant> is the digest size (224/256/384/512), <impl> the sha3_impl_name().

#include "newt_test.h"
#include "sha3.h"

static const unsigned kBlocks[] = {0, 1, 2, 4};
#define NUM_LENGTHS (sizeof(kBlocks) / sizeof(kBlocks[0]))
#define MAX_MSG (4 * 144)

static uint8_t msg[MAX_MSG] __attribute__((aligned(8)));

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

    uint8_t out[64] __attribute__((aligned(8)));
    uint8_t want[NUM_LENGTHS][64] __attribute__((aligned(8)));
    unsigned mismatches = 0;
    for (unsigned v = 0; v < SHA3_NUM_VARIANTS; v++) {
        unsigned rate = sha3_rate_bytes((sha3_variant_t)v);
        unsigned digest = sha3_digest_bytes((sha3_variant_t)v);
        for (unsigned l = 0; l < NUM_LENGTHS; l++)
            sha3_hash((sha3_variant_t)v, SHA3_IMPL_SW_XKCP_OPT64, msg, kBlocks[l] * rate, want[l]);
        // The MMIO accelerator (task 7.1) is measured for SHA3-256 only.
        const unsigned last_impl = (v == SHA3_256) ? SHA3_NUM_IMPLS : SHA3_FIRST_MMIO;
        for (unsigned impl = 0; impl < last_impl; impl++) {
            counts_t res[NUM_LENGTHS];
            // Warm-up with the longest message: every measurement then runs with
            // warm instruction and data caches (a shorter warm-up leaves the later
            // blocks of msg cold, adding misses that grow with the length).
            measure((sha3_variant_t)v, (sha3_impl_t)impl, msg,
                    kBlocks[NUM_LENGTHS - 1] * rate, out, 0);
            for (unsigned l = 0; l < NUM_LENGTHS; l++) {
                counts_t c =
                    measure((sha3_variant_t)v, (sha3_impl_t)impl, msg, kBlocks[l] * rate, out, 0);
                res[l].cycles = c.cycles - calib.cycles;
                res[l].instret = c.instret - calib.instret;
                for (unsigned b = 0; b < digest; b++)
                    if (out[b] != want[l][b]) {
                        printf("MISMATCH,%u,%s,%u\r\n", 8 * digest,
                               sha3_impl_name((sha3_impl_t)impl), kBlocks[l] * rate);
                        mismatches++;
                        break;
                    }
            }
            printf("RESULT,%u,%s,%u", 8 * digest,
                   sha3_impl_name((sha3_impl_t)impl), rate);
            for (unsigned l = 0; l < NUM_LENGTHS; l++)
                printf(",%u:%lu:%lu", kBlocks[l] * rate, res[l].cycles, res[l].instret);
            printf("\r\n");
        }
    }
    printf("sha3_bench: DONE (%u digest mismatches)\r\n", mismatches);
    newt_uart_flush();
    return newt_exit_code((int)mismatches);
}
