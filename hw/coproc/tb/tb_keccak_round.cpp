// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Unit test for keccak_round (combinational). Checks:
//   1. the C++ reference itself against the FIPS 202 known answer for
//      Keccak-f[1600] on the all-zero state (lanes 0..4);
//   2. 24 chained RTL rounds on the all-zero state equal that answer;
//   3. 1000 seeded random (state, round index) pairs: one RTL round equals
//      one reference round.
// Exit status 0 iff every check passes.

#include <cstdio>
#include <random>

#include "Vkeccak_round.h"  // model class is named after the top module
#include "keccak_ref.h"
#include "verilated.h"

using keccak_ref::State;

static void put_state(Vkeccak_round &dut, const State &s) {
    for (unsigned i = 0; i < 25; i++) {
        dut.state_i[2 * i] = static_cast<uint32_t>(s[i]);
        dut.state_i[2 * i + 1] = static_cast<uint32_t>(s[i] >> 32);
    }
}

static State get_state(const Vkeccak_round &dut) {
    State s{};
    for (unsigned i = 0; i < 25; i++)
        s[i] = (static_cast<uint64_t>(dut.state_o[2 * i + 1]) << 32) | dut.state_o[2 * i];
    return s;
}

static State rtl_round(Vkeccak_round &dut, const State &s, unsigned ir) {
    put_state(dut, s);
    dut.round_constant_i = keccak_ref::kRoundConstants[ir];
    dut.eval();
    return get_state(dut);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vkeccak_round dut;
    int fails = 0;

    // FIPS 202 / Keccak team intermediate values: Keccak-f[1600](0), lanes 0..4.
    static const uint64_t kZeroPerm[5] = {0xF1258F7940E1DDE7ull, 0x84D5CCF933C0478Aull,
                                          0xD598261EA65AA9EEull, 0xBD1547306F80494Dull,
                                          0x8B284E056253D057ull};

    State ref = keccak_ref::permute(State{});
    for (unsigned i = 0; i < 5; i++)
        if (ref[i] != kZeroPerm[i]) {
            std::printf("FAIL reference: zero-state lane %u = %016llx, want %016llx\n", i,
                        (unsigned long long)ref[i], (unsigned long long)kZeroPerm[i]);
            fails++;
        }

    State s{};
    for (unsigned ir = 0; ir < 24; ir++) s = rtl_round(dut, s, ir);
    for (unsigned i = 0; i < 25; i++)
        if (s[i] != ref[i]) {
            std::printf("FAIL rtl: zero-state 24 rounds, lane %u = %016llx, want %016llx\n", i,
                        (unsigned long long)s[i], (unsigned long long)ref[i]);
            fails++;
        }

    std::mt19937_64 rng(0x5EED0001ull);
    const unsigned kRandom = 1000;
    for (unsigned n = 0; n < kRandom; n++) {
        State in{};
        for (auto &l : in) l = rng();
        unsigned ir = static_cast<unsigned>(rng() % 24);
        State got = rtl_round(dut, in, ir), want = keccak_ref::round(in, ir);
        if (got != want) {
            if (fails < 10)
                for (unsigned i = 0; i < 25; i++)
                    if (got[i] != want[i])
                        std::printf("FAIL rtl: random #%u round %u lane %u = %016llx, want %016llx\n",
                                    n, ir, i, (unsigned long long)got[i],
                                    (unsigned long long)want[i]);
            fails++;
        }
    }

    std::printf("tb_keccak_round: %s (%d failures; 24-round zero-state KAT + %u random rounds)\n",
                fails ? "FAIL" : "PASS", fails, kRandom);
    return fails ? 1 : 0;
}
