// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Power workloads for keccak_mmio (openspec change sha3-cvxif-coprocessor,
// task 8.1, design D8), run on the block's gate-level model by
// block-synth.mk's power flow. Records switching activity as SAIF over a
// SHA3-256 absorb workload driven at the AXI port the way the SoC drives it.
// Per block of block_cycles cycles:
//
//   +mode=cpu   17 single-beat absorb writes, one starting every lane_gap
//               cycles (the CPU's lane stores), then a START write to CTRL,
//               then STATUS reads every poll_gap cycles until DONE, then idle
//               until the block's end
//   +mode=dma   one 17-beat INCR burst into the absorb window (the iDMA's
//               block copy), then START and the same polling
//   +mode=idle  nothing issued: the accelerator's idle power
//
// block_cycles follows the SoC measurements at RoundsPerCycle = 6 (the
// SHA3-256 split-model slopes of mmio-cpu and mmio-dma in
// docs/results/sha3-ise.md, message in the D-cache, and
// docs/results/sha3-mmio-uncached.md, message not cached; block-synth.mk's
// POWER_ARGS_* sets), so average power times block_cycles times the clock
// period is the energy per block. After the traced window all 25 lanes are
// read back and compared with the C++ reference.
//
// Plusargs: +mode=cpu|dma|idle (cpu) +blocks=N (32) +block_cycles=C (265)
//           +lane_gap=G (14) +poll_gap=P (4) +name=NAME
//           +saif=PATH (power.saif) +stats=PATH (power_workload.json)

#include <cstdio>
#include <random>
#include <string>
#include <vector>

#include "Vkeccak_mmio_tb_top.h"
#include "keccak_ref.h"
#include "verilated.h"
#include "verilated_saif_c.h"

namespace {

constexpr uint64_t kCtrl = 0x000, kStatus = 0x008, kAbsorb = 0x100, kState = 0x200;
constexpr uint64_t kStart = 2;
constexpr uint64_t kRate256 = 1;          // CTRL RATE field: SHA3-256
constexpr unsigned kLanesPerBlock = 17;   // SHA3-256 rate, 136 B
constexpr uint64_t kHalfPeriodPs = 5500;  // 11 ns clock

// Verilator matches a plusarg by its name without the leading '+'.
const char *plus_match(const char *name) {
    return Verilated::commandArgsPlusMatch(name[0] == '+' ? name + 1 : name);
}

unsigned plusarg(const char *name, unsigned dflt) {
    const char *v = plus_match(name);
    std::string s(v ? v : "");
    auto eq = s.find('=');
    return eq == std::string::npos ? dflt : static_cast<unsigned>(std::stoul(s.substr(eq + 1)));
}

std::string plusarg_str(const char *name, const char *dflt) {
    const char *v = plus_match(name);
    std::string s(v ? v : "");
    auto eq = s.find('=');
    return eq == std::string::npos ? dflt : s.substr(eq + 1);
}

class Bench {
  public:
    Vkeccak_mmio_tb_top dut;
    VerilatedSaifC *saif = nullptr;
    uint64_t time_ps = 0;
    uint64_t cycles = 0;
    int fails = 0;

    void half(int clk) {
        dut.clk_i = clk;
        dut.eval();
        if (saif) saif->dump(time_ps);
        time_ps += kHalfPeriodPs;
    }

    void tick() {
        half(1);
        half(0);
        cycles++;
    }

    void quiet() {
        dut.aw_valid_i = dut.w_valid_i = dut.ar_valid_i = 0;
        dut.b_ready_i = dut.r_ready_i = 1;
    }

    // One write of `data.size()` beats from addr (1 = a CPU store, 17 = the
    // iDMA's block copy); returns when the B response has been taken.
    void write(uint64_t addr, const std::vector<uint64_t> &data) {
        unsigned w_n = 0;
        bool aw_done = false;
        for (unsigned guard = 0;; guard++) {
            dut.aw_valid_i = !aw_done;
            dut.aw_addr_i = addr;
            dut.aw_len_i = static_cast<uint8_t>(data.size() - 1);
            dut.w_valid_i = w_n < data.size();
            dut.w_data_i = data[w_n < data.size() ? w_n : 0];
            dut.w_strb_i = 0xFF;
            dut.w_last_i = w_n + 1 == data.size();
            dut.b_ready_i = 1;
            dut.eval();
            const bool aw_fire = dut.aw_valid_i && dut.aw_ready_o;
            const bool w_fire = dut.w_valid_i && dut.w_ready_o;
            const bool b_fire = dut.b_valid_o;
            if (b_fire && dut.b_resp_o != 0) {
                std::printf("FAIL: write 0x%llx answered %u\n", (unsigned long long)addr,
                            dut.b_resp_o);
                fails++;
            }
            tick();
            aw_done |= aw_fire;
            w_n += w_fire;
            if (b_fire) break;
            if (guard > 2000) {
                std::printf("FAIL: write 0x%llx never answered\n", (unsigned long long)addr);
                fails++;
                break;
            }
        }
        quiet();
    }

    uint64_t read(uint64_t addr) {
        uint64_t data = 0;
        bool ar_done = false;
        for (unsigned guard = 0;; guard++) {
            dut.ar_valid_i = !ar_done;
            dut.ar_addr_i = addr;
            dut.r_ready_i = 1;
            dut.eval();
            const bool ar_fire = dut.ar_valid_i && dut.ar_ready_o;
            const bool r_fire = dut.r_valid_o;
            if (r_fire) data = dut.r_data_o;
            tick();
            ar_done |= ar_fire;
            if (r_fire) break;
            if (guard > 2000) {
                std::printf("FAIL: read 0x%llx never answered\n", (unsigned long long)addr);
                fails++;
                break;
            }
        }
        quiet();
        return data;
    }

    void idle_until(uint64_t cycle) {
        quiet();
        while (cycles < cycle) tick();
    }
};

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);
    const std::string mode = plusarg_str("+mode=", "cpu");
    const std::string name = plusarg_str("+name=", mode.c_str());
    const unsigned blocks = plusarg("+blocks=", 32);
    const unsigned block_cycles = plusarg("+block_cycles=", 265);
    const unsigned lane_gap = plusarg("+lane_gap=", 14);
    const unsigned poll_gap = plusarg("+poll_gap=", 4);
    const std::string saif_path = plusarg_str("+saif=", "power.saif");
    const std::string stats_path = plusarg_str("+stats=", "power_workload.json");
    const bool idle = mode == "idle", dma = mode == "dma";
    if (!idle && !dma && mode != "cpu") {
        std::printf("FAIL: +mode must be cpu, dma or idle\n");
        return 1;
    }

    Bench b;
    b.dut.rst_ni = 0;
    b.quiet();
    for (int i = 0; i < 4; i++) b.tick();
    b.dut.rst_ni = 1;
    b.tick();
    b.write(kCtrl, {(kRate256 << 2) | 1});  // clear, SHA3-256 rate
    b.idle_until(b.cycles + 16);

    std::mt19937_64 rng(0x5EED0008ull);
    keccak_ref::State want{};

    // Traced window: blocks x block_cycles cycles. The time base restarts at
    // 0 so the SAIF duration is exactly the window.
    b.time_ps = 0;
    b.saif = new VerilatedSaifC;
    b.dut.trace(b.saif, 99);
    b.saif->open(saif_path.c_str());
    const uint64_t t0 = b.cycles;
    unsigned overruns = 0;
    for (unsigned blk = 0; blk < blocks; blk++) {
        const uint64_t start = t0 + uint64_t(blk) * block_cycles;
        if (!idle) {
            std::vector<uint64_t> lanes(kLanesPerBlock);
            for (unsigned i = 0; i < kLanesPerBlock; i++) {
                lanes[i] = rng();
                want[i] ^= lanes[i];
            }
            if (dma) {
                b.write(kAbsorb, lanes);
            } else {
                for (unsigned i = 0; i < kLanesPerBlock; i++) {
                    b.idle_until(start + uint64_t(i) * lane_gap);
                    b.write(kAbsorb + 8 * i, {lanes[i]});
                }
            }
            want = keccak_ref::permute(want);
            b.write(kCtrl, {(kRate256 << 2) | kStart});
            for (unsigned guard = 0; guard < 200; guard++) {
                const uint64_t s = b.read(kStatus);
                if ((s & 1) == 0 && (s & 2)) break;
                b.idle_until(b.cycles + poll_gap);
            }
        }
        if (b.cycles > start + block_cycles) overruns++;
        b.idle_until(start + block_cycles);
    }
    const uint64_t traced = b.cycles - t0;
    b.saif->close();
    delete b.saif;
    b.saif = nullptr;

    if (overruns) {
        std::printf("FAIL: %u blocks overran block_cycles=%u\n", overruns, block_cycles);
        b.fails++;
    }
    for (unsigned i = 0; i < 25; i++) {
        const uint64_t got = b.read(kState + 8 * i);
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
                     "{\"name\": \"%s\", \"mode\": \"%s\", \"workload\": \"%s\", "
                     "\"blocks\": %u, \"block_cycles\": %u, \"lane_gap\": %u, \"poll_gap\": %u, "
                     "\"traced_cycles\": %llu, \"clock_period_ns\": 11.0, "
                     "\"functional_check\": \"%s\"}\n",
                     name.c_str(), mode.c_str(),
                     idle ? "idle (nothing issued)"
                          : (dma ? "SHA3-256 absorb, iDMA-fed, SoC-paced"
                                 : "SHA3-256 absorb, CPU-fed, SoC-paced"),
                     blocks, block_cycles, dma || idle ? 0 : lane_gap, poll_gap,
                     static_cast<unsigned long long>(traced), b.fails ? "FAIL" : "PASS");
        std::fclose(f);
    }
    std::printf("tb_keccak_mmio_power[%s]: %s (%s, %u blocks x %u cycles, %llu cycles traced)\n",
                name.c_str(), b.fails ? "FAIL" : "PASS", mode.c_str(), blocks, block_cycles,
                static_cast<unsigned long long>(traced));
    return b.fails ? 1 : 0;
}
