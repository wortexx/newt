// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// CV-X-IF bring-up smoke test against CVA6's stock example coprocessor
// (cvxif_example_coprocessor, wired in iguana_soc as temporary scaffolding).
// That coprocessor accepts two opcodes and computes rs1 + rs2:
//   custom-2 (0x5B): result written back to rd
//   custom-1 (0x2B): result discarded (writeback = 0), rd must stay unchanged
// It delays its result by a data-dependent number of cycles, which exercises
// the core's wait-for-result path, not only a same-cycle response.
//
// Known CVA6 (pulp-v1.0.0) quirk, characterised here rather than failed on:
// a non-writing offload whose encoding names rd != x0 still forwards its
// result to an instruction that reads rd in the writeback cycle
// (scoreboard.sv forwards on sbe.rd before clearing it to x0), although the
// register file is never written. The Keccak ISE therefore requires rd = x0
// for its non-writing instructions (sha3-cvxif-coprocessor design D3).

#include "newt_test.h"

static inline uint64_t copro_add_wb(uint64_t a, uint64_t b) {
    uint64_t r;
    asm volatile(".insn r 0x5B, 0, 0, %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}

// custom-1 with rd = x0, the encoding the Keccak ISE requires for non-writing ops.
static inline void copro_add_nowb_x0(uint64_t a, uint64_t b) {
    asm volatile(".insn r 0x2B, 0, 0, x0, %0, %1" ::"r"(a), "r"(b) : "memory");
}

// custom-1 with rd = the register holding `*keep`, read back by the very next
// instruction (`mv`) and again later from the register file.
static inline uint64_t copro_add_nowb_rd(uint64_t *keep, uint64_t a, uint64_t b) {
    uint64_t r = *keep, seen;
    asm volatile(
        ".insn r 0x2B, 0, 0, %0, %2, %3\n"
        "mv %1, %0\n"
        : "+r"(r), "=&r"(seen)
        : "r"(a), "r"(b));
    *keep = r;
    return seen;
}

int main(void) {
    newt_uart_init();
    printf("cvxif_example: start\r\n");

    static const uint64_t a[] = {0, 1, 0x123456789ABCDEF0ull, 0xFFFFFFFFFFFFFFFFull,
                                 0x8000000000000000ull, 0x00000000FFFFFFFFull};
    static const uint64_t b[] = {0, 2, 0x0FEDCBA987654321ull, 1,
                                 0x8000000000000000ull, 0x0000000000000001ull};
    for (unsigned i = 0; i < sizeof(a) / sizeof(a[0]); i++) {
        uint64_t r = copro_add_wb(a[i], b[i]);
        NEWT_CHECK(r == a[i] + b[i], "custom-2 #%u: got 0x%lx, want 0x%lx", i, r, a[i] + b[i]);
    }

    // Dependent chain: each offloaded result feeds the next offload.
    uint64_t acc = 0;
    for (unsigned i = 1; i <= 16; i++) acc = copro_add_wb(acc, i);
    NEWT_CHECK(acc == 136, "custom-2 chain: got %lu, want 136", acc);

    // No-writeback opcode with rd = x0: completes, and the next result still flows.
    copro_add_nowb_x0(5, 7);
    uint64_t after = copro_add_wb(40, 2);
    NEWT_CHECK(after == 42, "custom-2 after custom-1(x0): got %lu, want 42", after);

    // No-writeback opcode with rd != x0: the register file must keep the old
    // value; what the immediately dependent reader sees is the known quirk.
    uint64_t kept = 0xC0FFEEull;
    uint64_t seen = copro_add_nowb_rd(&kept, 5, 7);
    NEWT_CHECK(kept == 0xC0FFEEull, "custom-1 wrote the register file: got 0x%lx", kept);
    printf("cvxif_example: characterise: immediate reader saw 0x%lx (%s), regfile 0x%lx\r\n",
           seen, seen == 0xC0FFEEull ? "no leak" : "forwarding leak", kept);

    printf("cvxif_example: %s (%d failures)\r\n", newt_fails ? "FAIL" : "PASS", newt_fails);
    newt_uart_flush();
    return newt_fails;
}
