// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Baseline back-end: XKCP KeccakP-1600 ref64 (sw/vendor/xkcp-ref64), driven
// through XKCP's SnP state API exactly as XKCP's own sponge drives it:
// AddBytes a rate block, Permute_24rounds, then pad with AddByte(0x06) /
// AddByte(0x80) and ExtractBytes. The vendored source is compiled in this
// translation unit so its quoted #includes resolve inside its own directory
// (both XKCP variants ship a header named KeccakP-1600-SnP.h).

#include "../vendor/xkcp-ref64/KeccakP-1600-reference.c"

void sha3_sw_xkcp_ref64_hash(unsigned rate, unsigned digest, const uint8_t *msg, size_t len,
                           uint8_t *out);

void sha3_sw_xkcp_ref64_hash(unsigned rate, unsigned digest, const uint8_t *msg, size_t len,
                           uint8_t *out) {
    KeccakP1600_state state;
    KeccakP1600_Initialize(&state);
    while (len >= rate) {
        KeccakP1600_AddBytes(&state, msg, 0, rate);
        KeccakP1600_Permute_24rounds(&state);
        msg += rate;
        len -= rate;
    }
    KeccakP1600_AddBytes(&state, msg, 0, (unsigned)len);
    KeccakP1600_AddByte(&state, 0x06, (unsigned)len);
    KeccakP1600_AddByte(&state, 0x80, rate - 1);
    KeccakP1600_Permute_24rounds(&state);
    KeccakP1600_ExtractBytes(&state, out, 0, digest);
}
