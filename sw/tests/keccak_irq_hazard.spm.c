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
// The interrupt is the CLINT machine software interrupt (MSIP). It arrives
// only a few cycles after the store that raises it, so the trigger store is
// placed INSIDE the coprocessor sequence: compile-time variants put it after
// j coprocessor instructions, j swept across the sequence, and the interrupt
// is taken a couple of instructions later. (Two earlier designs raised MSIP
// before the sequence, once fenced and once with a swept delay; the interrupt
// always landed before the first coprocessor instruction, which a measured
// arrival-point diagnostic showed. A CLINT timer interrupt is too coarse:
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

#define A_STEP 4   // trigger positions for A: every 4th of 64 kxor
#define A_POS (64 / A_STEP + 1)
#define B_POS 14   // trigger positions for B: after 0..13 of 13 instructions

static volatile uint64_t irq_epc;
static volatile unsigned irq_count;

// Clear MSIP and wait until the clear is visible, so mret does not re-enter.
static inline void msip_clear(void) {
    *reg32(&__base_clint, CLINT_MSIP_REG_OFFSET) = 0;
    fence();
    while (*reg32(&__base_clint, CLINT_MSIP_REG_OFFSET) & 1) {
    }
}

// Overrides crt0's weak trap_vector. Only the software interrupt is expected.
void trap_vector(void) {
    uint64_t cause, epc;
    asm volatile("csrr %0, mcause" : "=r"(cause));
    asm volatile("csrr %0, mepc" : "=r"(epc));
    if (cause == ((1ull << 63) | 3)) {
        irq_epc = epc;
        irq_count = irq_count + 1;
        msip_clear();
        return;  // resume at mepc: the interrupted instruction re-executes
    }
    printf("unexpected trap: mcause 0x%lx mepc 0x%lx\r\n", cause, epc);
    newt_uart_flush();
    for (;;) wfi();
}

// Sequence A with the MSIP trigger store after J kxor (J = 0..64): kxor
// (1 << k) into lane 0 for k = 0..63. Writes the sequence's [start, end) PCs.
#define SEQ_A(J)                                                              \
    static void seq_a_##J(uint64_t *start, uint64_t *end) {                   \
        asm volatile("la %0, 1f\n"                                            \
                     "la %1, 2f\n"                                            \
                     "li t1, 1\n"                                             \
                     "li t0, 1\n"                                             \
                     "1:\n"                                                   \
                     ".rept " #J "\n"                                         \
                     ".insn r 0x2B, 1, 0, x0, t1, x0\n"                       \
                     "slli t1, t1, 1\n"                                       \
                     ".endr\n"                                                \
                     "sw t0, 0(%2)\n"                                         \
                     ".rept 64 - " #J "\n"                                    \
                     ".insn r 0x2B, 1, 0, x0, t1, x0\n"                       \
                     "slli t1, t1, 1\n"                                       \
                     ".endr\n"                                                \
                     "2:\n"                                                   \
                     : "=&r"(*start), "=&r"(*end)                             \
                     : "r"(msip_reg)                                          \
                     : "t0", "t1", "memory");                                 \
    }

// Sequence B (kxor lanes 0..4, then shatr rounds 0..7: 13 coprocessor
// instructions) with the trigger store after J of them (J = 0..13).
#define SEQ_B(J)                                                              \
    static void seq_b_##J(uint64_t *start, uint64_t *end) {                   \
        asm volatile("la %0, 1f\n"                                            \
                     "la %1, 2f\n"                                            \
                     "li t1, 0x0123456789ABCDEF\n"                            \
                     "li t2, 0\n"                                             \
                     "li t0, 1\n"                                             \
                     "1:\n"                                                   \
                     ".set n, 0\n"                                            \
                     ".rept 5\n"                                              \
                     ".if n == " #J "\n sw t0, 0(%2)\n .endif\n"              \
                     ".insn r 0x2B, 1, 0, x0, t1, t2\n"                       \
                     "addi t2, t2, 1\n"                                       \
                     "slli t1, t1, 3\n"                                       \
                     ".set n, n + 1\n"                                        \
                     ".endr\n"                                                \
                     "li t2, 0\n"                                             \
                     ".rept 8\n"                                              \
                     ".if n == " #J "\n sw t0, 0(%2)\n .endif\n"              \
                     ".insn r 0x2B, 3, 0, x0, t2, x0\n"                       \
                     "addi t2, t2, 1\n"                                       \
                     ".set n, n + 1\n"                                        \
                     ".endr\n"                                                \
                     ".if n == " #J "\n sw t0, 0(%2)\n .endif\n"              \
                     "2:\n"                                                   \
                     : "=&r"(*start), "=&r"(*end)                             \
                     : "r"(msip_reg)                                          \
                     : "t0", "t1", "t2", "memory");                           \
    }

static volatile uint32_t *const msip_reg = (volatile uint32_t *)0x02040000;  // __base_clint

SEQ_A(0) SEQ_A(4) SEQ_A(8) SEQ_A(12) SEQ_A(16) SEQ_A(20) SEQ_A(24) SEQ_A(28) SEQ_A(32)
SEQ_A(36) SEQ_A(40) SEQ_A(44) SEQ_A(48) SEQ_A(52) SEQ_A(56) SEQ_A(60) SEQ_A(64)
SEQ_B(0) SEQ_B(1) SEQ_B(2) SEQ_B(3) SEQ_B(4) SEQ_B(5) SEQ_B(6) SEQ_B(7) SEQ_B(8)
SEQ_B(9) SEQ_B(10) SEQ_B(11) SEQ_B(12) SEQ_B(13)

typedef void (*seq_fn)(uint64_t *, uint64_t *);

static const seq_fn seq_a_at[A_POS] = {
    seq_a_0,  seq_a_4,  seq_a_8,  seq_a_12, seq_a_16, seq_a_20, seq_a_24, seq_a_28, seq_a_32,
    seq_a_36, seq_a_40, seq_a_44, seq_a_48, seq_a_52, seq_a_56, seq_a_60, seq_a_64};
static const seq_fn seq_b_at[B_POS] = {seq_b_0, seq_b_1, seq_b_2,  seq_b_3,  seq_b_4,
                                       seq_b_5, seq_b_6, seq_b_7,  seq_b_8,  seq_b_9,
                                       seq_b_10, seq_b_11, seq_b_12, seq_b_13};

// One trial: clear state, enable interrupts, run a sequence that raises MSIP
// part-way through. Returns 1 if the interrupt was taken inside it.
static int trial(seq_fn seq, uint64_t *epc_off) {
    uint64_t start, end;
    keccak_kclr();
    irq_count = 0;
    irq_epc = 0;
    set_mie(1);
    seq(&start, &end);
    set_mie(0);
    if (irq_count == 0) {  // arrives after the sequence: wait for it, ignore the trial
        set_mie(1);
        while (irq_count == 0) {
        }
        set_mie(0);
        return 0;
    }
    *epc_off = irq_epc - start;  // as signed: < 0 before, >= end - start after
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
        unsigned inside = 0, corrupted = 0;
        for (unsigned pos = 0; pos < A_POS; pos++) {
            uint64_t off = 0;
            int in = trial(seq_a_at[pos], &off);
            uint64_t mask = keccak_krd(0) ^ ~0ull;
            inside += in;
            corrupted += (mask != 0);
            printf("A trigger@%u: irq at seq%+ld B%s, doubly-applied mask 0x%lx\r\n",
                   pos * A_STEP, (long)off, in ? " (inside)" : "", mask);
        }
        printf("RESULT,irq_hazard,A_kxor,trials=%u,irq_inside=%u,corrupted=%u\r\n", A_POS,
               inside, corrupted);
        exercised &= (inside > 0);
    }

    // --- B: kxor + shatr, compared with an uninterrupted run -----------------
    {
        uint64_t golden[25], s[25], start, end;
        keccak_kclr();
        set_mie(0);  // golden run: the trigger fires, but the interrupt is masked
        seq_b_13(&start, &end);
        read_state(golden);
        msip_clear();
        unsigned inside = 0, corrupted = 0;
        for (unsigned pos = 0; pos < B_POS; pos++) {
            uint64_t off = 0;
            int in = trial(seq_b_at[pos], &off);
            read_state(s);
            unsigned bad = 0;
            for (unsigned i = 0; i < 25; i++) bad += (s[i] != golden[i]);
            inside += in;
            corrupted += (bad != 0);
            printf("B trigger@%u: irq at seq%+ld B%s, %u lanes differ from uninterrupted\r\n",
                   pos, (long)off, in ? " (inside)" : "", bad);
        }
        printf("RESULT,irq_hazard,B_kxor_shatr,trials=%u,irq_inside=%u,corrupted=%u\r\n",
               B_POS, inside, corrupted);
        exercised &= (inside > 0);
    }

    printf("keccak_irq_hazard: %s\r\n",
           exercised ? "DONE (window exercised)" : "FAIL (no interrupt landed inside a sequence)");
    newt_uart_flush();
    return newt_exit_code(!exercised);
}
