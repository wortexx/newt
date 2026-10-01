// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Unit test for keccak_cvxif through keccak_cvxif_tb_top (flat CV-X-IF
// ports). Drives the issue/result handshake the way CVA6's cvxif_fu does and
// checks every block-observable scenario of spec keccak-coprocessor:
//   - encodings: the five valid ops are accepted; another funct3, a non-zero
//     funct7, rd != x0 on a non-writing op, and other opcodes are rejected
//     (and a rejected instruction leaves the state alone, produces no result)
//   - kclr / kxor / krd write and read back; only krd requests a write
//   - out-of-range lane (kxor, krd) and round (shatr) indices complete with an
//     illegal-instruction exception and leave the state unchanged
//   - software save and restore via krd / kclr / kxor
//   - shatr 0..23 == kperm == reference, on the zero state (KAT) and on
//     seeded random states
//   - krd issued right after kperm sees the permuted state
//   - the result id echoes the issue id; a result is held while not ready
// Also reports kperm's latency for this RoundsPerCycle build.

#include <cstdio>
#include <random>

#include "Vkeccak_cvxif_tb_top.h"
#include "keccak_ref.h"
#include "verilated.h"

#ifndef ROUNDS_PER_CYCLE
#error "build with -DROUNDS_PER_CYCLE=<n> matching -GRoundsPerCycle"
#endif

using keccak_ref::State;

namespace {

enum Funct3 : uint32_t { KCLR = 0, KXOR = 1, KRD = 2, SHATR = 3, KPERM = 4 };

constexpr uint32_t kCustom1 = 0x2B;
constexpr uint32_t kRs1 = 10, kRs2 = 11;  // register numbers are don't-care for the copro

uint32_t encode(uint32_t funct3, uint32_t rd, uint32_t funct7 = 0, uint32_t opcode = kCustom1) {
    return (funct7 << 25) | (kRs2 << 20) | (kRs1 << 15) | (funct3 << 12) | (rd << 7) | opcode;
}

struct Result {
    bool accepted = false;
    bool writeback = false;
    bool valid = false;
    unsigned id = 0;
    uint64_t data = 0;
    unsigned rd = 0;
    bool we = false;
    bool exc = false;
    unsigned exccode = 0;
    unsigned latency = 0;  // cycles from issue to result valid
};

class Bench {
  public:
    Vkeccak_cvxif_tb_top dut;
    uint64_t cycles = 0;
    int fails = 0;
    unsigned next_id = 0;

    void tick() {
        dut.clk_i = 0;
        dut.eval();
        dut.clk_i = 1;
        dut.eval();
        cycles++;
    }

    void reset() {
        dut.rst_ni = 0;
        dut.issue_valid_i = 0;
        dut.result_ready_i = 1;
        tick();
        tick();
        dut.rst_ni = 1;
        tick();
    }

    // Offer one instruction; if accepted, wait for and take its result.
    // `hold_cycles` keeps result_ready low for that many result cycles first.
    Result exec(uint32_t instr, uint64_t rs1 = 0, uint64_t rs2 = 0, unsigned hold_cycles = 0) {
        Result r;
        unsigned guard = 0;
        dut.clk_i = 0;
        dut.issue_valid_i = 0;
        dut.eval();
        while (!dut.issue_ready_o) {
            tick();
            if (++guard > 1000) { std::printf("FAIL: issue_ready stuck low\n"); fails++; return r; }
        }
        unsigned id = (next_id++) & 0x3;
        dut.issue_valid_i = 1;
        dut.issue_instr_i = instr;
        dut.issue_id_i = id;
        dut.issue_rs1_i = rs1;
        dut.issue_rs2_i = rs2;
        dut.eval();
        r.accepted = dut.issue_accept_o;
        r.writeback = dut.issue_writeback_o;
        tick();
        dut.issue_valid_i = 0;
        dut.issue_instr_i = 0;
        dut.eval();
        if (!r.accepted) {
            // No result may follow a rejected instruction.
            for (unsigned i = 0; i < 4; i++) {
                if (dut.result_valid_o) { std::printf("FAIL: result after reject\n"); fails++; }
                tick();
            }
            return r;
        }
        dut.result_ready_i = hold_cycles ? 0 : 1;
        dut.eval();
        while (!dut.result_valid_o) {
            tick();
            r.latency++;
            if (++guard > 1000) { std::printf("FAIL: no result\n"); fails++; return r; }
        }
        r.latency++;  // the cycle the result became visible
        // Optional back-pressure: the result must stay put.
        uint64_t held_data = dut.result_data_o;
        for (unsigned h = 0; h < hold_cycles; h++) {
            tick();
            if (!dut.result_valid_o || dut.result_data_o != held_data) {
                std::printf("FAIL: result not held under back-pressure\n");
                fails++;
            }
        }
        dut.result_ready_i = 1;
        dut.eval();
        r.valid = true;
        r.id = dut.result_id_o;
        r.data = dut.result_data_o;
        r.rd = dut.result_rd_o;
        r.we = dut.result_we_o;
        r.exc = dut.result_exc_o;
        r.exccode = dut.result_exccode_o;
        if (r.id != id) { std::printf("FAIL: result id %u, issued %u\n", r.id, id); fails++; }
        tick();  // handshake
        return r;
    }

    // Convenience wrappers; non-writing ops use rd = x0 as the ISA requires.
    Result kclr() { return exec(encode(KCLR, 0)); }
    Result kxor(uint64_t data, uint64_t lane) { return exec(encode(KXOR, 0), data, lane); }
    Result krd(uint64_t lane, unsigned rd = 5) { return exec(encode(KRD, rd), 0, lane); }
    Result shatr(uint64_t round) { return exec(encode(SHATR, 0), round); }
    Result kperm() { return exec(encode(KPERM, 0)); }

    State read_state() {
        State s{};
        for (unsigned i = 0; i < 25; i++) s[i] = krd(i).data;
        return s;
    }

    void load_state(const State &s) {
        kclr();
        for (unsigned i = 0; i < 25; i++) kxor(s[i], i);
    }

    void check(bool cond, const char *what) {
        if (!cond) { std::printf("FAIL: %s\n", what); fails++; }
    }

    void check_state(const State &got, const State &want, const char *what) {
        for (unsigned i = 0; i < 25; i++)
            if (got[i] != want[i]) {
                std::printf("FAIL: %s: lane %u = %016llx, want %016llx\n", what, i,
                            (unsigned long long)got[i], (unsigned long long)want[i]);
                fails++;
                return;
            }
    }

    // A result that must be a clean, non-writing completion.
    void check_ok_nowrite(const Result &r, const char *what) {
        if (!r.accepted || !r.valid || r.exc || r.we) {
            std::printf("FAIL: %s: accepted=%d valid=%d exc=%d we=%d\n", what, r.accepted,
                        r.valid, r.exc, r.we);
            fails++;
        }
    }

    // A result that must be an illegal-instruction exception without a write.
    void check_illegal(const Result &r, const char *what) {
        if (!r.accepted || !r.valid || !r.exc || r.exccode != 2 || r.we) {
            std::printf("FAIL: %s: accepted=%d exc=%d exccode=%u we=%d\n", what, r.accepted,
                        r.exc, r.exccode, r.we);
            fails++;
        }
    }
};

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Bench b;
    b.reset();
    std::mt19937_64 rng(0x5EED0002ull + ROUNDS_PER_CYCLE);

    // --- Encodings ---------------------------------------------------------
    b.check_ok_nowrite(b.kclr(), "kclr accepted");
    for (uint32_t f3 : {5u, 6u, 7u})
        b.check(!b.exec(encode(f3, 0)).accepted, "unassigned funct3 rejected");
    b.check(!b.exec(encode(KXOR, 0, 1)).accepted, "non-zero funct7 rejected");
    b.check(!b.exec(encode(KXOR, 0, 0x40)).accepted, "funct7 MSB rejected");
    for (uint32_t f3 : {KCLR, KXOR, SHATR, KPERM})
        b.check(!b.exec(encode(f3, 5)).accepted, "non-writing op with rd != x0 rejected");
    b.check(!b.exec(encode(KXOR, 0, 0, 0x0B)).accepted, "custom-0 opcode rejected");
    b.check(!b.exec(encode(KXOR, 0, 0, 0x5B)).accepted, "custom-2 opcode rejected");
    {
        Result r = b.krd(0, 0);
        b.check(r.accepted && r.writeback && r.we && r.rd == 0, "krd to x0 is legal");
        r = b.krd(0, 17);
        b.check(r.accepted && r.writeback && r.we && r.rd == 17, "krd writes its rd");
        r = b.kclr();
        b.check(!r.writeback && !r.we, "kclr requests no write");
    }

    // --- Write / read back --------------------------------------------------
    b.kclr();
    b.check_ok_nowrite(b.kxor(0x0123456789ABCDEFull, 7), "kxor lane 7");
    {
        State want{};
        want[7] = 0x0123456789ABCDEFull;
        b.check_state(b.read_state(), want, "write/read back");
        b.kxor(0x0123456789ABCDEFull, 7);
        b.check_state(b.read_state(), State{}, "kxor is XOR (twice = 0)");
    }

    // --- Rejected instructions leave the state alone ------------------------
    {
        State s{};
        for (auto &l : s) l = rng();
        b.load_state(s);
        b.exec(encode(5, 0));                // unassigned funct3
        b.exec(encode(KXOR, 0, 1), ~0ull, 3);  // non-zero funct7
        b.exec(encode(KXOR, 9), ~0ull, 3);   // rd != x0
        b.check_state(b.read_state(), s, "state after rejected encodings");

        // --- Out-of-range indices --------------------------------------------
        b.check_illegal(b.kxor(~0ull, 25), "kxor lane 25");
        b.check_illegal(b.kxor(~0ull, 1ull << 40), "kxor lane 2^40");
        b.check_illegal(b.krd(25), "krd lane 25");
        b.check_illegal(b.shatr(24), "shatr round 24");
        b.check_illegal(b.shatr(~0ull), "shatr round 2^64-1");
        b.check_state(b.read_state(), s, "state after out-of-range indices");

        // --- Save / restore ---------------------------------------------------
        State saved = b.read_state();
        b.kperm();
        b.load_state(saved);
        b.check_state(b.read_state(), saved, "save/restore");
    }

    // --- Permutation: KAT on the zero state ---------------------------------
    unsigned kperm_latency = 0;
    {
        b.kclr();
        Result r = b.kperm();
        kperm_latency = r.latency;
        b.check_ok_nowrite(r, "kperm");
        State want = keccak_ref::permute(State{});
        Result l0 = b.krd(0);  // issued right after kperm
        b.check(l0.data == 0xF1258F7940E1DDE7ull, "krd right after kperm sees KAT lane 0");
        b.check_state(b.read_state(), want, "kperm(0)");

        b.kclr();
        for (unsigned ir = 0; ir < 24; ir++) b.check_ok_nowrite(b.shatr(ir), "shatr");
        b.check_state(b.read_state(), want, "shatr 0..23 on zero state");
    }

    // --- Permutation: random states, shatr vs kperm vs reference ------------
    const unsigned kRandom = 20;
    for (unsigned n = 0; n < kRandom; n++) {
        State s{};
        for (auto &l : s) l = rng();
        State want = keccak_ref::permute(s);

        b.load_state(s);
        b.kperm();
        b.check_state(b.read_state(), want, "kperm(random)");

        b.load_state(s);
        for (unsigned ir = 0; ir < 24; ir++) b.shatr(ir);
        b.check_state(b.read_state(), want, "shatr 0..23 (random)");

        unsigned ir = static_cast<unsigned>(rng() % 24);
        b.load_state(s);
        b.shatr(ir);
        b.check_state(b.read_state(), keccak_ref::round(s, ir), "single shatr (random)");
    }

    // --- Back-pressure: result held while not ready -------------------------
    {
        b.kclr();
        b.kxor(0xDEADBEEFull, 3);
        Result r = b.exec(encode(KRD, 4), 0, 3, /*hold_cycles=*/5);
        b.check(r.valid && r.data == 0xDEADBEEFull && r.we, "krd under back-pressure");
    }

    std::printf("tb_keccak_cvxif[R=%d]: %s (%d failures; kperm latency %u cycles, %llu cycles total)\n",
                ROUNDS_PER_CYCLE, b.fails ? "FAIL" : "PASS", b.fails, kperm_latency,
                (unsigned long long)b.cycles);
    return b.fails ? 1 : 0;
}
