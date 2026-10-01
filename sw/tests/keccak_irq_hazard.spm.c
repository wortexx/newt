// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Characterises the Keccak ISE's interrupt hazard (spec keccak-coprocessor,
// "Documented operating constraint for interrupted sequences"; design D5).
// The pinned CVA6 never kills an instruction it has already offloaded, so a
// coprocessor instruction younger than the instruction an interrupt is taken
// at may already have changed the Keccak state before it is flushed and
// re-executed after mret. This test measures whether that happens.
//
// The interrupt is the CLINT machine software interrupt (MSIP): its arrival
// is a fixed number of cycles after the triggering store, so a swept spin
// delay before the coprocessor sequence walks the arrival point through the
// sequence one position at a time. (A CLINT timer interrupt is too coarse:
// mtime advances at the RTC rate, many core cycles per tick.)
//
//   A: 64 x kxor into lane 0, the k-th XORing (1 << k). The final lane XOR
//      all-ones is a bit mask of exactly the instructions whose effect was
//      applied an even number of times (here: twice).
//   B: kxor and 8 shatr rounds; the final 25 lanes are compared with an
//      uninterrupted run of the same sequence.
//
// Prints one RESULT line per experiment and the first corrupted trials. Exits
// 0 when every experiment had at least one interrupt land inside its
// sequence (i.e. the window was exercised); the corruption counts are the
// finding, not a pass/fail criterion.

#include "dif/clint.h"
#include "keccak_ise.h"
#include "newt_test.h"
#include "regs/clint.h"

#define NUM_PADS 160
#define MAX_REPORT 8

static volatile uint64_t irq_epc;
static volatile unsigned irq_count;

static inline void msip_set(uint32_t v) {
    *reg32(&__base_clint, CLINT_MSIP_REG_OFFSET) = v;
    fence();
}

// Overrides crt0's weak trap_vector. Only the software interrupt is expected.
void trap_vector(void) {
    uint64_t cause, epc;
    asm volatile("csrr %0, mcause" : "=r"(cause));
    asm volatile("csrr %0, mepc" : "=r"(epc));
    if (cause == ((1ull << 63) | 3)) {
        irq_epc = epc;
        irq_count = irq_count + 1;
        msip_set(0);
        while (*reg32(&__base_clint, CLINT_MSIP_REG_OFFSET) & 1) {
        }
        return;  // resume at mepc: the interrupted instruction re-executes
    }
    printf("unexpected trap: mcause 0x%lx mepc 0x%lx\r\n", cause, epc);
    newt_uart_flush();
    for (;;) wfi();
}

static inline void spin(uint64_t n) {
    asm volatile(
        "1: beqz %0, 2f\n"
        "   addi %0, %0, -1\n"
        "   j 1b\n"
        "2:\n"
        : "+r"(n));
}

// Experiment A sequence: kxor (1 << k) into lane 0 for k = 0..63.
// Returns the sequence's [start, end) PCs through the out pointers.
static void seq_a(uint64_t *start, uint64_t *end) {
    asm volatile(
        "la %0, 1f\n"
        "la %1, 2f\n"
        "li t1, 1\n"
        "1:\n"
        ".rept 64\n"
        ".insn r 0x2B, 1, 0, x0, t1, x0\n"
        "slli t1, t1, 1\n"
        ".endr\n"
        "2:\n"
        : "=&r"(*start), "=&r"(*end)
        :
        : "t1", "memory");
}

// Experiment B sequence: kxor lanes 0..4, then shatr rounds 0..7.
static void seq_b(uint64_t *start, uint64_t *end) {
    asm volatile(
        "la %0, 1f\n"
        "la %1, 2f\n"
        "li t1, 0x0123456789ABCDEF\n"
        "li t2, 0\n"
        "1:\n"
        ".rept 5\n"
        ".insn r 0x2B, 1, 0, x0, t1, t2\n"
        "addi t2, t2, 1\n"
        "slli t1, t1, 3\n"
        ".endr\n"
        "li t2, 0\n"
        ".rept 8\n"
        ".insn r 0x2B, 3, 0, x0, t2, x0\n"
        "addi t2, t2, 1\n"
        ".endr\n"
        "2:\n"
        : "=&r"(*start), "=&r"(*end)
        :
        : "t1", "t2", "memory");
}

typedef void (*seq_fn)(uint64_t *, uint64_t *);

// One trial: clear state, raise MSIP, spin `pad`, run the sequence with
// interrupts enabled. Returns 1 if the interrupt was taken inside it.
static int trial(seq_fn seq, uint64_t pad, uint64_t *epc_off) {
    uint64_t start, end;
    keccak_kclr();
    irq_count = 0;
    irq_epc = 0;
    set_mie(1);
    msip_set(1);
    spin(pad);
    seq(&start, &end);
    set_mie(0);
    if (irq_count == 0) {  // arrived after the sequence: take it now, ignore
        set_mie(1);
        while (irq_count == 0) {
        }
        set_mie(0);
        return 0;
    }
    *epc_off = irq_epc - start;
    return irq_epc >= start && irq_epc < end;
}

static void read_state(uint64_t s[25]) {
    for (unsigned i = 0; i < 25; i++) s[i] = keccak_krd(i);
}

int main(void) {
    newt_uart_init();
    set_mie(0);
    asm volatile("csrs mie, %0" ::"r"(1u << 3));  // MSIE
    int exercised = 1;

    // --- A: identify doubly-applied kxor by bit position ---------------------
    {
        unsigned inside = 0, corrupted = 0, reported = 0;
        for (uint64_t pad = 0; pad < NUM_PADS; pad++) {
            uint64_t off = 0;
            int in = trial(seq_a, pad, &off);
            uint64_t mask = keccak_krd(0) ^ ~0ull;
            inside += in;
            if (mask) {
                corrupted++;
                if (reported++ < MAX_REPORT)
                    printf("A pad %lu: irq at seq+%lu, doubly-applied kxor mask 0x%lx\r\n",
                           pad, off, mask);
            }
        }
        printf("RESULT,irq_hazard,A_kxor,trials=%u,irq_inside=%u,corrupted=%u\r\n", NUM_PADS,
               inside, corrupted);
        exercised &= (inside > 0);
    }

    // --- B: kxor + shatr, compared with an uninterrupted run -----------------
    {
        uint64_t golden[25], s[25], start, end;
        keccak_kclr();
        seq_b(&start, &end);
        read_state(golden);
        unsigned inside = 0, corrupted = 0, reported = 0;
        for (uint64_t pad = 0; pad < NUM_PADS; pad++) {
            uint64_t off = 0;
            int in = trial(seq_b, pad, &off);
            read_state(s);
            unsigned bad = 0;
            for (unsigned i = 0; i < 25; i++) bad += (s[i] != golden[i]);
            inside += in;
            if (bad) {
                corrupted++;
                if (reported++ < MAX_REPORT)
                    printf("B pad %lu: irq at seq+%lu, %u lanes differ from uninterrupted run\r\n",
                           pad, off, bad);
            }
        }
        printf("RESULT,irq_hazard,B_kxor_shatr,trials=%u,irq_inside=%u,corrupted=%u\r\n",
               NUM_PADS, inside, corrupted);
        exercised &= (inside > 0);
    }

    printf("keccak_irq_hazard: %s\r\n",
           exercised ? "DONE (window exercised)" : "FAIL (no interrupt landed inside a sequence)");
    newt_uart_flush();
    return exercised ? 0 : 1;
}
