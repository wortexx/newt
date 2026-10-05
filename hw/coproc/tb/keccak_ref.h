// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Independent C++ reference for Keccak-f[1600] (FIPS 202), used as the golden
// model by the hw/coproc unit testbenches. Written from the specification's
// step mappings, deliberately not from the RTL. Lane i = x + 5*y.

#pragma once

#include <array>
#include <cstdint>

namespace keccak_ref {

using State = std::array<uint64_t, 25>;

static const uint64_t kRoundConstants[24] = {
    0x0000000000000001ull, 0x0000000000008082ull, 0x800000000000808Aull,
    0x8000000080008000ull, 0x000000000000808Bull, 0x0000000080000001ull,
    0x8000000080008081ull, 0x8000000000008009ull, 0x000000000000008Aull,
    0x0000000000000088ull, 0x0000000080008009ull, 0x000000008000000Aull,
    0x000000008000808Bull, 0x800000000000008Bull, 0x8000000000008089ull,
    0x8000000000008003ull, 0x8000000000008002ull, 0x8000000000000080ull,
    0x000000000000800Aull, 0x800000008000000Aull, 0x8000000080008081ull,
    0x8000000000008080ull, 0x0000000080000001ull, 0x8000000080008008ull};

inline uint64_t rotl(uint64_t v, unsigned n) { return n ? (v << n) | (v >> (64 - n)) : v; }

// rho offsets computed as in FIPS 202 Algorithm 3 (not copied from a table).
inline std::array<unsigned, 25> rho_offsets() {
    std::array<unsigned, 25> r{};
    unsigned x = 1, y = 0;
    for (unsigned t = 0; t < 24; t++) {
        r[x + 5 * y] = ((t + 1) * (t + 2) / 2) % 64;
        unsigned nx = y, ny = (2 * x + 3 * y) % 5;
        x = nx;
        y = ny;
    }
    return r;
}

inline State round(const State &a, unsigned ir) {
    static const std::array<unsigned, 25> rho = rho_offsets();
    State t = a, b{}, out{};
    // theta
    uint64_t c[5], d[5];
    for (unsigned x = 0; x < 5; x++) c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20];
    for (unsigned x = 0; x < 5; x++) d[x] = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1);
    for (unsigned i = 0; i < 25; i++) t[i] ^= d[i % 5];
    // rho + pi: A'[x, y] = A[(x + 3y) mod 5, x]  (FIPS 202 Algorithm 3)
    for (unsigned x = 0; x < 5; x++)
        for (unsigned y = 0; y < 5; y++) {
            unsigned sx = (x + 3 * y) % 5, sy = x;
            b[x + 5 * y] = rotl(t[sx + 5 * sy], rho[sx + 5 * sy]);
        }
    // chi
    for (unsigned x = 0; x < 5; x++)
        for (unsigned y = 0; y < 5; y++)
            out[x + 5 * y] = b[x + 5 * y] ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y]);
    // iota
    out[0] ^= kRoundConstants[ir];
    return out;
}

inline State permute(State s) {
    for (unsigned ir = 0; ir < 24; ir++) s = round(s, ir);
    return s;
}

}  // namespace keccak_ref
