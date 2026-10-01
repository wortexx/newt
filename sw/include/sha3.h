// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// SHA3-224/256/384/512 (FIPS 202) over several Keccak-f[1600] back-ends, so
// tests and benchmarks run the identical sponge on each implementation:
//   SHA3_IMPL_ISE_KPERM  coprocessor, one kperm per block
//   SHA3_IMPL_ISE_SHATR  coprocessor, 24 shatr per block (arXiv:2508.20653)
// Further back-ends (software baselines, MMIO accelerator) are added by the
// sha3-cvxif-coprocessor change in later tasks.

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
    SHA3_NUM_IMPLS
} sha3_impl_t;

// Rate (bytes) and digest length (bytes) of a variant.
unsigned sha3_rate_bytes(sha3_variant_t v);
unsigned sha3_digest_bytes(sha3_variant_t v);
const char *sha3_variant_name(sha3_variant_t v);
const char *sha3_impl_name(sha3_impl_t impl);

// Hash `len` bytes of `msg` into `out` (sha3_digest_bytes(v) bytes).
// Returns 0, or -1 for an unknown variant or implementation.
int sha3_hash(sha3_variant_t v, sha3_impl_t impl, const uint8_t *msg, size_t len,
              uint8_t *out);
