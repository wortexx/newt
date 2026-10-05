// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Baseline back-end: the riscv-crypto reference SHA-3 (sw/vendor/
// riscv-crypto-sha3), called through its own Keccak() sponge, unmodified.
// The vendored source is compiled as part of this translation unit so that
// its quoted #include resolves inside the vendor directory.

#include "../vendor/riscv-crypto-sha3/Keccak.c"

void sha3_sw_rvcrypto_hash(unsigned rate, unsigned digest, const uint8_t *msg, size_t len,
                           uint8_t *out);

void sha3_sw_rvcrypto_hash(unsigned rate, unsigned digest, const uint8_t *msg, size_t len,
                           uint8_t *out) {
    Keccak(8 * rate, 1600 - 8 * rate, msg, len, 0x06, out, digest);
}
