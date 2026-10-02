// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Unit test for keccak_mmio through keccak_mmio_tb_top (flat single-beat AXI
// channels; the harness is the AXI manager). Checks the block-observable
// scenarios of spec keccak-mmio-accelerator and design D6:
//   - reset: STATUS reads not-busy / not-done, CTRL reads the SHA3-256 rate
//   - clear / absorb / start / poll / read: for every rate, the state equals
//     the C++ reference permutation of the absorbed lanes
//   - SHA3-224/256/384/512 digests of several message lengths equal a C++
//     sponge over the reference permutation, and SHA3-256("") equals the
//     FIPS 202 known answer
//   - every undefined offset or direction (unassigned offsets, absorb lanes
//     past the rate or lane 24, absorb reads, STATE / STATUS writes)
//     answers SLVERR and leaves the state unchanged
//   - a write while busy is held until the permutation ends and is then
//     applied (it does not corrupt the permutation); STATUS stays readable
//   - byte strobes: a partial absorb write XORs only the strobed bytes
//   - burst absorb: one INCR burst over a whole rate block (the iDMA's access
//     pattern) absorbs every beat into its lane, twice in a row, then permutes
// Also reports the START-to-DONE latency for this RoundsPerCycle build.

#include <cstdio>
#include <random>
#include <vector>

#include "Vkeccak_mmio_tb_top.h"
#include "keccak_ref.h"
#include "verilated.h"

#ifndef ROUNDS_PER_CYCLE
#error "build with -DROUNDS_PER_CYCLE=<n> matching -GRoundsPerCycle"
#endif

using keccak_ref::State;

namespace {

constexpr uint64_t kCtrl = 0x000, kStatus = 0x008, kAbsorb = 0x100, kState = 0x200;
constexpr uint64_t kClear = 1, kStart = 2;
constexpr unsigned kOkay = 0, kSlvErr = 2;
constexpr unsigned kRateLanes[4] = {18, 17, 13, 9};  // SHA3-224/256/384/512
constexpr unsigned kDigestBytes[4] = {28, 32, 48, 64};

struct Resp {
    unsigned resp = 0;
    uint64_t data = 0;
    unsigned cycles = 0;  // from request to response
};

class Bench {
  public:
    Vkeccak_mmio_tb_top dut;
    uint64_t cycles = 0;
    int fails = 0;

    void tick() {
        dut.clk_i = 0;
        dut.eval();
        dut.clk_i = 1;
        dut.eval();
        cycles++;
    }

    void reset() {
        dut.rst_ni = 0;
        dut.aw_valid_i = dut.w_valid_i = dut.ar_valid_i = 0;
        dut.b_ready_i = dut.r_ready_i = 0;
        tick();
        tick();
        dut.rst_ni = 1;
        tick();
    }

    Resp write(uint64_t addr, uint64_t data, uint8_t strb = 0xFF) {
        Resp r;
        dut.aw_valid_i = 1;
        dut.aw_addr_i = addr;
        dut.aw_len_i = 0;
        dut.w_last_i = 1;
        dut.w_valid_i = 1;
        dut.w_data_i = data;
        dut.w_strb_i = strb;
        dut.b_ready_i = 1;
        for (unsigned guard = 0;; guard++) {
            dut.clk_i = 0;
            dut.eval();
            const bool aw_fire = dut.aw_valid_i && dut.aw_ready_o;
            const bool w_fire = dut.w_valid_i && dut.w_ready_o;
            const bool b_fire = dut.b_valid_o;
            if (b_fire) r.resp = dut.b_resp_o;
            tick();
            r.cycles++;
            if (aw_fire) dut.aw_valid_i = 0;
            if (w_fire) dut.w_valid_i = 0;
            if (b_fire) break;
            if (guard > 2000) {
                std::printf("FAIL: write 0x%llx never answered\n", (unsigned long long)addr);
                fails++;
                break;
            }
        }
        dut.aw_valid_i = dut.w_valid_i = 0;
        dut.b_ready_i = 0;
        return r;
    }

    // Two writes issued back to back: the second address/data beat is offered
    // as soon as the first is accepted, without waiting for the first
    // response. Returns both responses with the cycle each arrived.
    struct Stamped {
        unsigned resp;
        uint64_t at;
    };
    std::vector<Stamped> write_pair(uint64_t a0, uint64_t d0, uint64_t a1, uint64_t d1) {
        const uint64_t addr[2] = {a0, a1}, data[2] = {d0, d1};
        unsigned aw_n = 0, w_n = 0;
        std::vector<Stamped> out;
        dut.b_ready_i = 1;
        for (unsigned guard = 0; out.size() < 2; guard++) {
            dut.aw_valid_i = aw_n < 2;
            dut.aw_addr_i = addr[aw_n < 2 ? aw_n : 1];
            dut.aw_len_i = 0;
            dut.w_last_i = 1;
            dut.w_valid_i = w_n < 2;
            dut.w_data_i = data[w_n < 2 ? w_n : 1];
            dut.w_strb_i = 0xFF;
            dut.clk_i = 0;
            dut.eval();
            const bool aw_fire = dut.aw_valid_i && dut.aw_ready_o;
            const bool w_fire = dut.w_valid_i && dut.w_ready_o;
            if (dut.b_valid_o) out.push_back({dut.b_resp_o, cycles});
            tick();
            aw_n += aw_fire;
            w_n += w_fire;
            if (guard > 2000) {
                check(false, "write pair never answered");
                break;
            }
        }
        dut.aw_valid_i = dut.w_valid_i = 0;
        dut.b_ready_i = 0;
        return out;
    }

    // One INCR burst of data.size() 8-byte beats from addr, as the iDMA issues
    // a block copy: the address phase once, then the beats back to back.
    Resp write_burst(uint64_t addr, const std::vector<uint64_t> &data) {
        Resp r;
        unsigned w_n = 0;
        bool aw_done = false;
        dut.b_ready_i = 1;
        for (unsigned guard = 0;; guard++) {
            dut.aw_valid_i = !aw_done;
            dut.aw_addr_i = addr;
            dut.aw_len_i = static_cast<uint8_t>(data.size() - 1);
            dut.w_valid_i = w_n < data.size();
            dut.w_data_i = data[w_n < data.size() ? w_n : 0];
            dut.w_strb_i = 0xFF;
            dut.w_last_i = w_n + 1 == data.size();
            dut.clk_i = 0;
            dut.eval();
            const bool aw_fire = dut.aw_valid_i && dut.aw_ready_o;
            const bool w_fire = dut.w_valid_i && dut.w_ready_o;
            const bool b_fire = dut.b_valid_o;
            if (b_fire) r.resp = dut.b_resp_o;
            tick();
            r.cycles++;
            aw_done |= aw_fire;
            w_n += w_fire;
            if (b_fire) break;
            if (guard > 4000) {
                std::printf("FAIL: burst to 0x%llx never answered\n", (unsigned long long)addr);
                fails++;
                break;
            }
        }
        dut.aw_valid_i = dut.w_valid_i = 0;
        dut.b_ready_i = 0;
        return r;
    }

    Resp read(uint64_t addr) {
        Resp r;
        dut.ar_valid_i = 1;
        dut.ar_addr_i = addr;
        dut.r_ready_i = 1;
        for (unsigned guard = 0;; guard++) {
            dut.clk_i = 0;
            dut.eval();
            const bool ar_fire = dut.ar_valid_i && dut.ar_ready_o;
            const bool r_fire = dut.r_valid_o;
            if (r_fire) {
                r.resp = dut.r_resp_o;
                r.data = dut.r_data_o;
                if (!dut.r_last_o) {
                    std::printf("FAIL: single-beat read without r_last\n");
                    fails++;
                }
            }
            tick();
            r.cycles++;
            if (ar_fire) dut.ar_valid_i = 0;
            if (r_fire) break;
            if (guard > 2000) {
                std::printf("FAIL: read 0x%llx never answered\n", (unsigned long long)addr);
                fails++;
                break;
            }
        }
        dut.ar_valid_i = 0;
        dut.r_ready_i = 0;
        return r;
    }

    void check(bool cond, const char *what) {
        if (!cond) {
            std::printf("FAIL: %s\n", what);
            fails++;
        }
    }

    void expect_ok(const Resp &r, const char *what) { check(r.resp == kOkay, what); }
    void expect_err(const Resp &r, const char *what) { check(r.resp == kSlvErr, what); }

    void set_rate(unsigned rate) { expect_ok(write(kCtrl, uint64_t(rate) << 2), "set rate"); }

    // Start a permutation and poll STATUS until DONE; returns the cycles taken.
    unsigned permute() {
        const uint64_t t0 = cycles;
        expect_ok(write(kCtrl, (uint64_t(rate) << 2) | kStart), "start");
        for (unsigned guard = 0; guard < 1000; guard++) {
            Resp s = read(kStatus);
            expect_ok(s, "status read");
            if ((s.data & 1) == 0 && (s.data & 2)) return unsigned(cycles - t0);
        }
        check(false, "permutation never finished");
        return 0;
    }

    State read_state() {
        State s{};
        for (unsigned i = 0; i < 25; i++) {
            Resp r = read(kState + 8 * i);
            expect_ok(r, "state read");
            s[i] = r.data;
        }
        return s;
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

    // SHA-3 on the accelerator (CPU-style feeding: lane-wise absorb writes).
    std::vector<uint8_t> hash(unsigned variant, const std::vector<uint8_t> &msg) {
        rate = variant;
        const unsigned rate_bytes = 8 * kRateLanes[variant];
        expect_ok(write(kCtrl, (uint64_t(variant) << 2) | kClear), "clear");
        std::vector<uint8_t> padded = msg;
        padded.push_back(0x06);
        while (padded.size() % rate_bytes) padded.push_back(0);
        padded.back() ^= 0x80;
        for (size_t off = 0; off < padded.size(); off += rate_bytes) {
            for (unsigned i = 0; i < kRateLanes[variant]; i++) {
                uint64_t lane = 0;
                for (unsigned k = 0; k < 8; k++)
                    lane |= uint64_t(padded[off + 8 * i + k]) << (8 * k);
                expect_ok(write(kAbsorb + 8 * i, lane), "absorb");
            }
            permute();
        }
        std::vector<uint8_t> out;
        for (unsigned i = 0; out.size() < kDigestBytes[variant]; i++) {
            const uint64_t lane = read(kState + 8 * i).data;
            for (unsigned k = 0; k < 8 && out.size() < kDigestBytes[variant]; k++)
                out.push_back(uint8_t(lane >> (8 * k)));
        }
        return out;
    }

    unsigned rate = 1;
};

// Reference sponge over keccak_ref::permute.
std::vector<uint8_t> ref_hash(unsigned variant, const std::vector<uint8_t> &msg) {
    const unsigned rate_bytes = 8 * kRateLanes[variant];
    std::vector<uint8_t> padded = msg;
    padded.push_back(0x06);
    while (padded.size() % rate_bytes) padded.push_back(0);
    padded.back() ^= 0x80;
    State s{};
    for (size_t off = 0; off < padded.size(); off += rate_bytes) {
        for (unsigned i = 0; i < kRateLanes[variant]; i++)
            for (unsigned k = 0; k < 8; k++)
                s[i] ^= uint64_t(padded[off + 8 * i + k]) << (8 * k);
        s = keccak_ref::permute(s);
    }
    std::vector<uint8_t> out;
    for (unsigned i = 0; out.size() < kDigestBytes[variant]; i++)
        for (unsigned k = 0; k < 8 && out.size() < kDigestBytes[variant]; k++)
            out.push_back(uint8_t(s[i] >> (8 * k)));
    return out;
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Bench b;
    b.reset();
    std::mt19937_64 rng(0x5EED0006ull + ROUNDS_PER_CYCLE);

    // --- Reset values ------------------------------------------------------
    {
        Resp s = b.read(kStatus);
        b.expect_ok(s, "status after reset");
        b.check(s.data == 0, "not busy, not done after reset");
        Resp c = b.read(kCtrl);
        b.check(c.resp == kOkay && c.data == (1u << 2), "CTRL reads the SHA3-256 rate after reset");
    }

    // --- Clear / absorb / start / read, every rate --------------------------
    unsigned perm_cycles = 0;
    for (unsigned rate = 0; rate < 4; rate++) {
        b.rate = rate;
        b.expect_ok(b.write(kCtrl, (uint64_t(rate) << 2) | kClear), "clear");
        b.check_state(b.read_state(), State{}, "state after clear");
        State s{};
        for (unsigned i = 0; i < kRateLanes[rate]; i++) {
            s[i] = rng();
            b.expect_ok(b.write(kAbsorb + 8 * i, s[i]), "absorb");
        }
        b.check_state(b.read_state(), s, "absorbed lanes read back");
        perm_cycles = b.permute();
        b.check_state(b.read_state(), keccak_ref::permute(s), "permutation");
        b.expect_ok(b.write(kCtrl, (uint64_t(rate) << 2) | kClear), "clear");
        b.check(b.read(kStatus).data == 0, "CLEAR drops DONE");
    }

    // --- Digests ---------------------------------------------------------------
    {
        const std::vector<uint8_t> want_empty = {
            0xa7, 0xff, 0xc6, 0xf8, 0xbf, 0x1e, 0xd7, 0x66, 0x51, 0xc1, 0x47,
            0x56, 0xa0, 0x61, 0xd6, 0x62, 0xf5, 0x80, 0xff, 0x4d, 0xe4, 0x3b,
            0x49, 0xfa, 0x82, 0xd8, 0x0a, 0x4b, 0x80, 0xf8, 0x43, 0x4a};
        b.check(b.hash(1, {}) == want_empty, "SHA3-256(\"\") known answer");
        for (unsigned variant = 0; variant < 4; variant++) {
            const unsigned rb = 8 * kRateLanes[variant];
            for (unsigned len : {0u, 1u, rb - 1, rb, rb + 1, 2 * rb + 5}) {
                std::vector<uint8_t> msg(len);
                for (auto &x : msg) x = uint8_t(rng());
                if (b.hash(variant, msg) != ref_hash(variant, msg)) {
                    std::printf("FAIL: digest, variant %u, length %u\n", variant, len);
                    b.fails++;
                }
            }
        }
    }

    // --- SLVERR, state unchanged ------------------------------------------------
    {
        b.rate = 3;  // SHA3-512: absorb lanes 0..8
        b.expect_ok(b.write(kCtrl, (3u << 2) | kClear), "clear");
        State s{};
        for (unsigned i = 0; i < 9; i++) {
            s[i] = rng();
            b.write(kAbsorb + 8 * i, s[i]);
        }
        b.expect_err(b.write(0x010, ~0ull), "write to an unassigned offset");
        b.expect_err(b.read(0x010), "read of an unassigned offset");
        b.expect_err(b.write(0xFF8, ~0ull), "write at the top of the region");
        b.expect_err(b.write(kAbsorb + 8 * 9, ~0ull), "absorb past the SHA3-512 rate");
        b.expect_err(b.write(kAbsorb + 8 * 25, ~0ull), "absorb past lane 24");
        b.expect_err(b.read(kAbsorb), "absorb window read");
        b.expect_err(b.write(kState, ~0ull), "state window write");
        b.expect_err(b.read(kState + 8 * 25), "state read past lane 24");
        b.expect_err(b.write(kStatus, ~0ull), "status write");
        b.check_state(b.read_state(), s, "state after SLVERR accesses");
        b.check(b.read(kStatus).data == 0, "SLVERR accesses start nothing");
    }

    // --- STATUS while busy -------------------------------------------------------
    {
        // A STATUS read issued right behind START sees BUSY when the
        // permutation is long enough to still be running when it arrives.
        b.expect_ok(b.write(kCtrl, (1u << 2) | kClear), "clear");
        b.expect_ok(b.write(kCtrl, (1u << 2) | kStart), "start");
        Resp st = b.read(kStatus);
        b.expect_ok(st, "status read during a permutation");
        if (24 / ROUNDS_PER_CYCLE > 6) b.check(st.data & 1, "STATUS reads busy during a permutation");
        while (b.read(kStatus).data & 1) {
        }
    }

    // --- Write while busy: held, then applied -----------------------------------
    {
        b.rate = 1;
        b.expect_ok(b.write(kCtrl, (1u << 2) | kClear), "clear");
        State s{};
        for (unsigned i = 0; i < 17; i++) {
            s[i] = rng();
            b.write(kAbsorb + 8 * i, s[i]);
        }
        // START, then an absorb write right behind it: the write reaches the
        // accelerator while the permutation runs and must be held, not merged.
        const uint64_t extra = rng();
        auto rs = b.write_pair(kCtrl, (1u << 2) | kStart, kAbsorb + 8 * 3, extra);
        b.check(rs.size() == 2 && rs[0].resp == kOkay && rs[1].resp == kOkay,
                "start and write while busy answered OKAY");
        const unsigned perm_len = 24 / ROUNDS_PER_CYCLE;
        b.check(rs.size() == 2 && rs[1].at - rs[0].at >= perm_len,
                "write while busy answered only after the permutation");
        State want = keccak_ref::permute(s);
        want[3] ^= extra;
        b.check_state(b.read_state(), want, "write while busy applied after the permutation");
        b.check(b.read(kStatus).data == 2, "done, not busy, after the held write");
    }

    // --- Byte strobes -------------------------------------------------------------
    {
        b.expect_ok(b.write(kCtrl, (1u << 2) | kClear), "clear");
        b.expect_ok(b.write(kAbsorb + 8 * 5, 0x1122334455667788ull, 0x0F), "strobed absorb");
        State want{};
        want[5] = 0x0000000055667788ull;
        b.check_state(b.read_state(), want, "only strobed bytes absorbed");
    }

    // --- Burst absorb, every rate ---------------------------------------------------
    for (unsigned rate = 0; rate < 4; rate++) {
        b.rate = rate;
        b.expect_ok(b.write(kCtrl, (uint64_t(rate) << 2) | kClear), "clear");
        State s{};
        for (unsigned pass = 0; pass < 2; pass++) {
            std::vector<uint64_t> block(kRateLanes[rate]);
            for (unsigned i = 0; i < block.size(); i++) {
                block[i] = rng();
                s[i] ^= block[i];
            }
            b.expect_ok(b.write_burst(kAbsorb, block), "burst absorb");
            b.check_state(b.read_state(), s, "burst absorbed every beat");
        }
        b.permute();
        b.check_state(b.read_state(), keccak_ref::permute(s), "permutation after burst absorb");
    }

    std::printf("tb_keccak_mmio[R=%d]: %s (%d failures; START-to-DONE %u cycles incl. polling, "
                "%llu cycles total)\n",
                ROUNDS_PER_CYCLE, b.fails ? "FAIL" : "PASS", b.fails, perm_cycles,
                (unsigned long long)b.cycles);
    return b.fails ? 1 : 0;
}
