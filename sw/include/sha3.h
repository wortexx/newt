// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// SHA3-224/256/384/512 (FIPS 202) over several Keccak-f[1600] back-ends, so
// tests and benchmarks run the identical sponge on each implementation:
//   SHA3_IMPL_ISE_KPERM       coprocessor, one kperm per block
//   SHA3_IMPL_ISE_SHATR       coprocessor, 24 shatr per block (arXiv:2508.20653)
//   SHA3_IMPL_SW_RVCRYPTO     riscv-crypto reference SHA-3, its own sponge
//   SHA3_IMPL_SW_XKCP_REF64   XKCP KeccakP-1600 ref-64bits (Keccak Team reference)
//   SHA3_IMPL_SW_XKCP_OPT64   XKCP KeccakP-1600 opt64 (generic64)
//   SHA3_IMPL_MMIO_CPU        keccak_mmio accelerator, lanes stored by the CPU
//   SHA3_IMPL_MMIO_DMA        keccak_mmio accelerator, blocks copied by the iDMA
// The software baselines are vendored under sw/vendor/ (design D7).

#pragma once

#include <stddef.h>
#include <stdint.h>

typedef enum {
    SHA3_224 = 0,
    SHA3_256 = 1,
    SHA3_384 = 2,
    SHA3_512 = 3,
    SHA3_NUM_VARIANTS
} sha3_variant_t;

typedef enum {
    SHA3_IMPL_ISE_KPERM = 0,
    SHA3_IMPL_ISE_SHATR = 1,
    SHA3_IMPL_SW_RVCRYPTO = 2,
    SHA3_IMPL_SW_XKCP_REF64 = 3,
    SHA3_IMPL_SW_XKCP_OPT64 = 4,
    SHA3_IMPL_MMIO_CPU = 5,
    SHA3_IMPL_MMIO_DMA = 6,
    SHA3_NUM_IMPLS
} sha3_impl_t;

// Implementations [SHA3_FIRST_ISE, SHA3_FIRST_SW) use the coprocessor,
// [SHA3_FIRST_SW, SHA3_FIRST_MMIO) are software baselines and
// [SHA3_FIRST_MMIO, SHA3_NUM_IMPLS) use the MMIO accelerator.
#define SHA3_FIRST_ISE SHA3_IMPL_ISE_KPERM
#define SHA3_FIRST_SW SHA3_IMPL_SW_RVCRYPTO
#define SHA3_FIRST_MMIO SHA3_IMPL_MMIO_CPU

// Rate (bytes) and digest length (bytes) of a variant.
unsigned sha3_rate_bytes(sha3_variant_t v);
unsigned sha3_digest_bytes(sha3_variant_t v);
const char *sha3_variant_name(sha3_variant_t v);
const char *sha3_impl_name(sha3_impl_t impl);

// Hash `len` bytes of `msg` into `out` (sha3_digest_bytes(v) bytes).
// Returns 0, or -1 for an unknown variant or implementation.
int sha3_hash(sha3_variant_t v, sha3_impl_t impl, const uint8_t *msg, size_t len,
              uint8_t *out);
