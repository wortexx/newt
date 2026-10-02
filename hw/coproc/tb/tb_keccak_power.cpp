// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Power workload for keccak_cvxif (openspec change sha3-cvxif-coprocessor,
// task 5.2, design D8), run on the block's gate-level model by
// block-synth.mk's power flow. Records switching activity as SAIF over a
// SHA3-256 absorb workload paced like the SoC:
//
//   every block_cycles cycles: 17 kxor (rate 136 B = 17 lanes), one every
//   lane_gap cycles, then kperm, then idle until the block's end.
//
// The defaults (+block_cycles=135 +lane_gap=7) follow the SoC measurement at
// RoundsPerCycle = 6 (docs/results/sha3-ise.md: SHA3-256 kperm, 135
// cycles/block; the absorb loop issues a kxor every ~7 cycles), so average
// power times block_cycles times the clock period is the energy per block.
// The lane data is a fixed pseudo-random stream, like message bytes.
//
// After the traced window, all 25 lanes are read back and compared with the
// C++ reference: the run doubles as a gate-level functional check.
//
// Plusargs: +blocks=N (32) +block_cycles=C (135) +lane_gap=G (7)
//           +saif=PATH (power.saif) +stats=PATH (power_workload.json)
// The clock period for the SAIF timestamps is fixed at 11 ns (the block's
// synthesis constraint), so toggle densities come out per real nanosecond.

#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>

#include "Vkeccak_cvxif_tb_top.h"
#include "keccak_ref.h"
#include "verilated.h"
#include "verilated_saif_c.h"

namespace {

constexpr uint32_t kCustom1 = 0x2B;
constexpr unsigned kLanesPerBlock = 17;  // SHA3-256 rate, 136 bytes
constexpr uint64_t kHalfPeriodPs = 5500;  // 11 ns clock

enum Funct3 : uint32_t { KCLR = 0, KXOR = 1, KRD = 2, KPERM = 4 };

uint32_t encode(uint32_t funct3, uint32_t rd) {
    return (11u << 20) | (10u << 15) | (funct3 << 12) | (rd << 7) | kCustom1;
}

unsigned plusarg(const char *name, unsigned dflt) {
    const char *v = Verilated::commandArgsPlusMatch(name);
    std::string s(v ? v : "");
    auto eq = s.find('=');
    return eq == std::string::npos ? dflt : static_cast<unsigned>(std::stoul(s.substr(eq + 1)));
}

std::string plusarg_str(const char *name, const char *dflt) {
    const char *v = Verilated::commandArgsPlusMatch(name);
    std::string s(v ? v : "");
    auto eq = s.find('=');
    return eq == std::string::npos ? dflt : s.substr(eq + 1);
}

class Bench {
  public:
    Vkeccak_cvxif_tb_top dut;
    VerilatedSaifC *saif = nullptr;
    uint64_t time_ps = 0;
    uint64_t cycles = 0;
    unsigned next_id = 0;
    unsigned results = 0;
    int fails = 0;

    void half(int clk) {
        dut.clk_i = clk;
        dut.eval();
        if (saif) saif->dump(time_ps);
        time_ps += kHalfPeriodPs;
    }

    // One clock cycle. Inputs are set by the caller before the rising edge;
    // a result offered this cycle is taken (result_ready is always 1).
    void tick() {
        dut.eval();
        if (dut.result_valid_o) results++;
        half(1);
        half(0);
        cycles++;
    }

    void idle() {
        dut.issue_valid_i = 0;
        tick();
    }

    void issue(uint32_t instr, uint64_t rs1 = 0, uint64_t rs2 = 0) {
        dut.issue_valid_i = 1;
        dut.issue_instr_i = instr;
        dut.issue_id_i = (next_id++) & 0x3;
        dut.issue_rs1_i = rs1;
        dut.issue_rs2_i = rs2;
        dut.eval();
        if (!dut.issue_ready_o || !dut.issue_accept_o) {
            std::printf("FAIL: offload not accepted (ready=%d accept=%d)\n", dut.issue_ready_o,
                        dut.issue_accept_o);
            fails++;
        }
        tick();
        dut.issue_valid_i = 0;
    }

    void drain() {
        for (unsigned i = 0; i < 64; i++) idle();
    }

    uint64_t krd(uint64_t lane) {
        issue(encode(KRD, 5), 0, lane);
        for (unsigned guard = 0; guard < 64; guard++) {
            dut.eval();
            if (dut.result_valid_o) {
                uint64_t data = dut.result_data_o;
                tick();
                return data;
            }
            tick();
        }
        std::printf("FAIL: no krd result\n");
        fails++;
        return 0;
    }
};

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);
    const unsigned blocks = plusarg("+blocks=", 32);
    const unsigned block_cycles = plusarg("+block_cycles=", 135);
    const unsigned lane_gap = plusarg("+lane_gap=", 7);
    const std::string saif_path = plusarg_str("+saif=", "power.saif");
    const std::string stats_path = plusarg_str("+stats=", "power_workload.json");
    if (kLanesPerBlock * lane_gap >= block_cycles) {
        std::printf("FAIL: 17 x lane_gap must leave room for kperm in block_cycles\n");
        return 1;
    }

    Bench b;
    b.dut.rst_ni = 0;
    b.dut.issue_valid_i = 0;
    b.dut.result_ready_i = 1;
    for (int i = 0; i < 4; i++) b.tick();
    b.dut.rst_ni = 1;
    b.tick();
    b.issue(encode(KCLR, 0));
    b.drain();

    std::mt19937_64 rng(0x5EED0005ull);
    keccak_ref::State want{};
    const unsigned results_before = b.results;

    // Traced window: blocks x block_cycles cycles, nothing else. The time base
    // restarts at 0 so the SAIF duration is exactly the window.
    b.time_ps = 0;
    b.saif = new VerilatedSaifC;
    b.dut.trace(b.saif, 99);
    b.saif->open(saif_path.c_str());
    const uint64_t t0 = b.cycles;
    for (unsigned blk = 0; blk < blocks; blk++) {
        for (unsigned c = 0; c < block_cycles; c++) {
            if (c % lane_gap == 0 && c / lane_gap < kLanesPerBlock) {
                const unsigned lane = c / lane_gap;
                const uint64_t data = rng();
                want[lane] ^= data;
                b.issue(encode(KXOR, 0), data, lane);
            } else if (c == kLanesPerBlock * lane_gap) {
                want = keccak_ref::permute(want);
                b.issue(encode(KPERM, 0));
            } else {
                b.idle();
            }
        }
    }
    const uint64_t traced = b.cycles - t0;
    b.saif->close();
    delete b.saif;
    b.saif = nullptr;

    b.drain();
    const unsigned completed = b.results - results_before;
    const unsigned expected = blocks * (kLanesPerBlock + 1);
    if (completed != expected) {
        std::printf("FAIL: %u results for %u issued instructions\n", completed, expected);
        b.fails++;
    }
    for (unsigned i = 0; i < 25; i++) {
        const uint64_t got = b.krd(i);
        if (got != want[i]) {
            std::printf("FAIL: lane %u = %016llx, want %016llx\n", i,
                        static_cast<unsigned long long>(got),
                        static_cast<unsigned long long>(want[i]));
            b.fails++;
            break;
        }
    }

    FILE *f = std::fopen(stats_path.c_str(), "w");
    if (f) {
        std::fprintf(f,
                     "{\"workload\": \"SHA3-256 absorb, SoC-paced\", \"blocks\": %u, "
                     "\"block_cycles\": %u, \"lane_gap\": %u, \"traced_cycles\": %llu, "
                     "\"clock_period_ns\": 11.0, \"functional_check\": \"%s\"}\n",
                     blocks, block_cycles, lane_gap, static_cast<unsigned long long>(traced),
                     b.fails ? "FAIL" : "PASS");
        std::fclose(f);
    }
    std::printf("tb_keccak_power: %s (%u blocks x %u cycles, lane_gap %u, %llu cycles traced)\n",
                b.fails ? "FAIL" : "PASS", blocks, block_cycles, lane_gap,
                static_cast<unsigned long long>(traced));
    return b.fails ? 1 : 0;
}
