// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Uncached-message SHA3-256 benchmark for the ISE-vs-MMIO comparison (spec
// sha3-evaluation, "Measured ISE-versus-MMIO crossover"; task 7.2), for the
// two ISE back-ends and both MMIO modes, at 0..224 full rate blocks (1..225
// permutations including the padding block).
//
// sha3_bench measures with the message in CVA6's D-cache: its messages are at
// most 544 bytes and are warmed up. A long message cannot stay there: the
// D-cache is 16 KiB (cv64a6_imafdcsclic_sv39), so the ISE back-ends, whose
// lanes are CPU loads, stream it from the SPM, while the iDMA reads the SPM
// directly in either case. This benchmark measures every length in that
// regime: before each timed call the D-cache is filled with other data (28 KiB
// of the program image, read as data, twice), so the message is not cached.
// The two regimes are reported separately, not fitted together.
//
// The longest length is what the lane can hold: the program runs from the
// 64 KiB SPM (LLC as scratchpad), the boot ROM puts the stack at its top, and
// the message must fit between the program and the stack. Moving it to DRAM
// would change the memory system being compared. The program checks the gap
// at run time and fails if the stack reserve does not fit.
//
// Otherwise the method of sha3_bench: mcycle/minstret around the call minus
// the measured counter-read overhead, one untimed warm-up per implementation
// on the longest message (instruction cache, accelerator, iDMA), interrupts
// disabled. Every timed digest is compared
// with the untimed XKCP opt64 digest of the same message (MISMATCH line and a
// failing exit code on any difference).
//
// Output (parsed by scripts/sha3_eval.py, merged with sha3_bench's points):
//   REGIME,uncached
//   CALIB,<cycles>,<instret>
//   RESULT,256,<impl>,136,<bytes>:<cycles>:<instret>,...
//   MISMATCH,256,<impl>,<bytes>      (only on a wrong digest)

#include "newt_test.h"
#include "sha3.h"

#define RATE 136u
#define MAX_BLOCKS 224u
#define STACK_RESERVE 4096u
#define SPM_BYTES (64u * 1024u)

#define EVICT_BYTES (28u * 1024u)

static const unsigned kBlocks[] = {0, 1, 2, 4, 8, 32, 96, MAX_BLOCKS};
#define NUM_LENGTHS (sizeof(kBlocks) / sizeof(kBlocks[0]))

static const sha3_impl_t kImpls[] = {SHA3_IMPL_ISE_KPERM, SHA3_IMPL_ISE_SHATR,
                                     SHA3_IMPL_MMIO_CPU, SHA3_IMPL_MMIO_DMA};
#define NUM_IMPLS (sizeof(kImpls) / sizeof(kImpls[0]))

// In .bulk (after .bss, not zeroed by crt0): filled below.
static uint8_t msg[MAX_BLOCKS * RATE] __attribute__((aligned(8), section(".bulk")));

typedef struct {
    uint64_t cycles, instret;
} counts_t;

// Fill the D-cache with the program image (read as data, one load per 16-byte
// line, twice for the pseudo-random replacement), evicting the message.
static void evict_message(void) {
    volatile const uint64_t *p = (volatile const uint64_t *)&__base_spm;
    uint64_t sink = 0;
    for (unsigned pass = 0; pass < 2; pass++)
        for (unsigned k = 0; k < EVICT_BYTES / 8; k += 2) sink += p[k];
    asm volatile("" ::"r"(sink));
}

static __attribute__((noinline)) counts_t measure(sha3_impl_t impl, const uint8_t *m, size_t len,
                                                  uint8_t *out, int empty) {
    uint64_t c0, i0, c1, i1;
    asm volatile("csrr %0, mcycle\n csrr %1, minstret" : "=r"(c0), "=r"(i0)::"memory");
    if (!empty) sha3_hash(SHA3_256, impl, m, len, out);
    asm volatile("csrr %0, mcycle\n csrr %1, minstret" : "=r"(c1), "=r"(i1)::"memory");
    counts_t r = {c1 - c0, i1 - i0};
    return r;
}

int main(void) {
    newt_uart_init();
    set_mie(0);

    // The message must end below the stack reserve at the top of the SPM.
    uintptr_t msg_end = (uintptr_t)(msg + sizeof(msg));
    uintptr_t stack_floor = (uintptr_t)&__base_spm + SPM_BYTES - STACK_RESERVE;
    uintptr_t sp;
    asm volatile("mv %0, sp" : "=r"(sp));
    printf("sha3_bench_long: msg 0x%lx..0x%lx, stack floor 0x%lx, sp 0x%lx\r\n",
           (unsigned long)(uintptr_t)msg, (unsigned long)msg_end, (unsigned long)stack_floor,
           (unsigned long)sp);
    if (msg_end > stack_floor || sp < stack_floor) {
        printf("sha3_bench_long: FAIL message buffer overlaps the stack reserve\r\n");
        newt_uart_flush();
        return newt_exit_code(1);
    }
    for (unsigned k = 0; k < sizeof(msg); k++) msg[k] = (uint8_t)(31 * k + 7);

    counts_t calib = {~0ull, ~0ull};
    for (unsigned n = 0; n < 8; n++) {
        counts_t e = measure(SHA3_IMPL_ISE_KPERM, msg, 0, 0, 1);
        if (e.cycles < calib.cycles) calib = e;
    }
    printf("REGIME,uncached\r\n");
    printf("CALIB,%lu,%lu\r\n", calib.cycles, calib.instret);

    uint8_t want[NUM_LENGTHS][32] __attribute__((aligned(8)));
    for (unsigned l = 0; l < NUM_LENGTHS; l++)
        sha3_hash(SHA3_256, SHA3_IMPL_SW_XKCP_OPT64, msg, kBlocks[l] * RATE, want[l]);

    uint8_t out[32] __attribute__((aligned(8)));
    unsigned mismatches = 0;
    for (unsigned k = 0; k < NUM_IMPLS; k++) {
        sha3_impl_t impl = kImpls[k];
        counts_t res[NUM_LENGTHS];
        measure(impl, msg, MAX_BLOCKS * RATE, out, 0);  // warm-up
        for (unsigned l = 0; l < NUM_LENGTHS; l++) {
            evict_message();
            counts_t c = measure(impl, msg, kBlocks[l] * RATE, out, 0);
            res[l].cycles = c.cycles - calib.cycles;
            res[l].instret = c.instret - calib.instret;
            for (unsigned b = 0; b < 32; b++)
                if (out[b] != want[l][b]) {
                    printf("MISMATCH,256,%s,%u\r\n", sha3_impl_name(impl), kBlocks[l] * RATE);
                    mismatches++;
                    break;
                }
        }
        printf("RESULT,256,%s,%u", sha3_impl_name(impl), RATE);
        for (unsigned l = 0; l < NUM_LENGTHS; l++)
            printf(",%u:%lu:%lu", kBlocks[l] * RATE, res[l].cycles, res[l].instret);
        printf("\r\n");
    }
    printf("sha3_bench_long: DONE (%u digest mismatches)\r\n", mismatches);
    newt_uart_flush();
    return newt_exit_code((int)mismatches);
}
