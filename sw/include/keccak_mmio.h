// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Register access for the memory-mapped Keccak-f[1600] accelerator
// (hw/coproc/keccak_mmio.sv; spec keccak-mmio-accelerator). 4 KiB at
// 0x5000_0000 on Cheshire's external AXI port, uncached and non-idempotent
// for CVA6. See hw/coproc/README.md for the register map.

#pragma once

#include <stdint.h>

#define KECCAK_MMIO_BASE 0x50000000ul

#define KECCAK_MMIO_CTRL 0x000u
#define KECCAK_MMIO_STATUS 0x008u
#define KECCAK_MMIO_ABSORB 0x100u  // + 8 * lane, write: lane ^= data
#define KECCAK_MMIO_STATE 0x200u   // + 8 * lane, read

#define KECCAK_MMIO_CTRL_CLEAR (1u << 0)
#define KECCAK_MMIO_CTRL_START (1u << 1)
#define KECCAK_MMIO_CTRL_RATE_SHIFT 2  // 0..3: SHA3-224/256/384/512
#define KECCAK_MMIO_STATUS_BUSY (1u << 0)
#define KECCAK_MMIO_STATUS_DONE (1u << 1)

static inline volatile uint64_t *keccak_mmio_reg(unsigned offset) {
    return (volatile uint64_t *)(KECCAK_MMIO_BASE + offset);
}

// Rate select for a rate in bytes (144/136/104/72).
static inline uint64_t keccak_mmio_rate_sel(unsigned rate_bytes) {
    return rate_bytes == 144 ? 0 : rate_bytes == 136 ? 1 : rate_bytes == 104 ? 2 : 3;
}

static inline void keccak_mmio_clear(unsigned rate_bytes) {
    *keccak_mmio_reg(KECCAK_MMIO_CTRL) =
        KECCAK_MMIO_CTRL_CLEAR | (keccak_mmio_rate_sel(rate_bytes) << KECCAK_MMIO_CTRL_RATE_SHIFT);
}

static inline void keccak_mmio_absorb(unsigned lane, uint64_t data) {
    *keccak_mmio_reg(KECCAK_MMIO_ABSORB + 8 * lane) = data;
}

static inline uint64_t keccak_mmio_read(unsigned lane) {
    return *keccak_mmio_reg(KECCAK_MMIO_STATE + 8 * lane);
}

// Start a permutation and poll until it is done. The rate field is written
// with START, so pass the rate in use.
static inline void keccak_mmio_permute(unsigned rate_bytes) {
    *keccak_mmio_reg(KECCAK_MMIO_CTRL) =
        KECCAK_MMIO_CTRL_START | (keccak_mmio_rate_sel(rate_bytes) << KECCAK_MMIO_CTRL_RATE_SHIFT);
    while (!(*keccak_mmio_reg(KECCAK_MMIO_STATUS) & KECCAK_MMIO_STATUS_DONE)) {
    }
}
