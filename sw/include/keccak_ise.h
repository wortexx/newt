// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Intrinsics for the Keccak-f[1600] CV-X-IF coprocessor (hw/coproc/
// keccak_cvxif.sv; spec keccak-coprocessor). R-type on custom-1 (0x2B),
// funct7 = 0. Non-writing instructions hard-wire rd = x0, as the ISA
// requires (the pinned CVA6 would otherwise forward their result to a
// reader of rd). `asm volatile` keeps the coprocessor instructions in
// program order; the coprocessor state is invisible to the compiler.
//
// Lane i addresses x = i % 5, y = i / 5 (FIPS 202), little-endian lanes.

#pragma once

#include <stdint.h>

// kclr: state := 0
static inline void keccak_kclr(void) {
    asm volatile(".insn r 0x2B, 0, 0, x0, x0, x0" ::: "memory");
}

// kxor: state[lane] ^= data
static inline void keccak_kxor(uint64_t data, uint64_t lane) {
    asm volatile(".insn r 0x2B, 1, 0, x0, %0, %1" ::"r"(data), "r"(lane) : "memory");
}

// krd: returns state[lane]
static inline uint64_t keccak_krd(uint64_t lane) {
    uint64_t r;
    asm volatile(".insn r 0x2B, 2, 0, %0, x0, %1" : "=r"(r) : "r"(lane) : "memory");
    return r;
}

// shatr: one Keccak-f[1600] round with round index `round` (0..23)
static inline void keccak_shatr(uint64_t round) {
    asm volatile(".insn r 0x2B, 3, 0, x0, %0, x0" ::"r"(round) : "memory");
}

// kperm: the full 24-round Keccak-f[1600]
static inline void keccak_kperm(void) {
    asm volatile(".insn r 0x2B, 4, 0, x0, x0, x0" ::: "memory");
}
