// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Known-answer and integration test for the Keccak MMIO accelerator
// (hw/coproc/keccak_mmio.sv; spec keccak-mmio-accelerator), on the SoC:
//   - region reachable: STATUS reads 0 (not busy, not done) after reset with
//     an OKAY response (an error would trap), and a Cheshire scratch register
//     written before is unchanged after the accelerator accesses
//   - every vector of sw/vectors/sha3_kat_vectors.h through both driver
//     modes (CPU stores, iDMA copies), from an aligned and an unaligned copy
//   - undefined offset: a store to an unassigned offset, past the rate and
//     to STATE, and a read of the absorb window, complete (no hang) and leave
//     a loaded accelerator state unchanged; a hash afterwards is still
//     correct. The SLVERR itself is checked at the AXI boundary by
//     hw/coproc/tb/tb_keccak_mmio.cpp: this CVA6 (pulp-v1.0.0) raises access
//     faults only from translation/PMP and drops AXI error responses
//     (wt_axi_adapter), and iguana builds Cheshire without its bus-error
//     units (BusErr = 0), so the error code is not observable here. Any trap
//     the accesses do raise is reported.
//   - coexistence: a coprocessor state survives an MMIO hash, and an
//     accelerator state survives an ISE hash
// Prints PASS/FAIL per check and returns newt_exit_code(failures).

#include "keccak_ise.h"
#include "keccak_mmio.h"
#include "newt_test.h"
#include "regs/cheshire.h"
#include "sha3.h"
#include "sha3_kat_vectors.h"

#define KAT_MAX_LEN 512u

static uint8_t msg_buf[KAT_MAX_LEN + 8] __attribute__((aligned(8)));
static uint8_t md_buf[64 + 8] __attribute__((aligned(8)));

static volatile unsigned n_traps;
static volatile uint64_t last_cause;

// Overrides crt0's weak trap_vector: record, then step over the instruction.
void trap_vector(void) {
    uint64_t cause, epc;
    asm volatile("csrr %0, mcause" : "=r"(cause));
    asm volatile("csrr %0, mepc" : "=r"(epc));
    last_cause = cause;
    n_traps = n_traps + 1;
    uint16_t lo = *(volatile uint16_t *)epc;
    asm volatile("csrw mepc, %0" ::"r"(epc + (((lo & 0x3) == 0x3) ? 4 : 2)));
}

static int fails;

static void check(int ok, const char *what) {
    if (!ok) {
        printf("FAIL %s\r\n", what);
        fails++;
    }
}

static int kat(const sha3_kat_t *t, sha3_impl_t impl, unsigned off) {
    uint8_t *m = msg_buf + off, *d = md_buf + off;
    for (unsigned b = 0; b < t->len; b++) m[b] = t->msg[b];
    sha3_hash(t->variant, impl, m, t->len, d);
    for (unsigned b = 0; b < sha3_digest_bytes(t->variant); b++)
        if (d[b] != t->md[b]) return 0;
    return 1;
}

int main(void) {
    newt_uart_init();
    set_mie(0);
    printf("sha3_kat_mmio: %u vectors x %u implementations\r\n", SHA3_NUM_KATS,
           (unsigned)(SHA3_NUM_IMPLS - SHA3_FIRST_MMIO));

    // --- Region reachable, no aliasing ----------------------------------------
    {
        volatile uint32_t *scratch = reg32(&__base_regs, CHESHIRE_SCRATCH_15_REG_OFFSET);
        *scratch = 0x5A5AC3C3u;
        unsigned base = n_traps;
        uint64_t status = *keccak_mmio_reg(KECCAK_MMIO_STATUS);
        uint64_t ctrl = *keccak_mmio_reg(KECCAK_MMIO_CTRL);
        check(n_traps == base, "STATUS/CTRL reads complete without an error");
        check(status == 0, "STATUS reads not busy, not done after reset");
        check(ctrl == (1u << KECCAK_MMIO_CTRL_RATE_SHIFT), "CTRL reads the SHA3-256 rate");
        check(*scratch == 0x5A5AC3C3u, "Cheshire scratch register unchanged");
        printf("sha3_kat_mmio: region at 0x%lx reachable\r\n", KECCAK_MMIO_BASE);
    }

    // --- Known answers, both modes, aligned and unaligned ----------------------
    for (unsigned k = 0; k < SHA3_NUM_KATS; k++) {
        const sha3_kat_t *t = &sha3_kats[k];
        if (t->len > KAT_MAX_LEN) {
            printf("FAIL vector %u: len %u exceeds the copy buffer\r\n", k, (unsigned)t->len);
            fails++;
            continue;
        }
        for (unsigned impl = SHA3_FIRST_MMIO; impl < SHA3_NUM_IMPLS; impl++)
            for (unsigned off = 0; off < 2; off++)
                if (!kat(t, (sha3_impl_t)impl, off)) {
                    printf("FAIL %s %s vector %u (len %u, %s): digest mismatch\r\n",
                           sha3_variant_name(t->variant), sha3_impl_name((sha3_impl_t)impl), k,
                           (unsigned)t->len, off ? "unaligned" : "aligned");
                    fails++;
                }
    }
    printf("sha3_kat_mmio: %u vectors done on both modes\r\n", SHA3_NUM_KATS);

    // --- Undefined offset -> completes, state unchanged ------------------------
    {
        keccak_mmio_clear(136);  // SHA3-256 rate: 17 absorb lanes
        for (unsigned i = 0; i < 17; i++) keccak_mmio_absorb(i, 0xA5A5A5A5A5A5A5A5ull ^ i);
        unsigned base = n_traps;
        *keccak_mmio_reg(0x010) = ~0ull;                        // unassigned offset
        *keccak_mmio_reg(KECCAK_MMIO_ABSORB + 8 * 20) = ~0ull;  // absorb lane past the rate
        *keccak_mmio_reg(KECCAK_MMIO_STATE) = ~0ull;            // STATE is read-only
        fence();
        volatile uint64_t v = *keccak_mmio_reg(KECCAK_MMIO_ABSORB);  // absorb window read
        (void)v;
        printf("sha3_kat_mmio: undefined accesses completed, %u traps (last mcause %lu)\r\n",
               n_traps - base, n_traps == base ? 0ul : (unsigned long)last_cause);
        int same = 1;
        for (unsigned i = 0; i < 25; i++)
            same &= (keccak_mmio_read(i) == (i < 17 ? 0xA5A5A5A5A5A5A5A5ull ^ i : 0));
        check(same, "undefined accesses leave the accelerator state unchanged");
        check(kat(&sha3_kats[0], SHA3_IMPL_MMIO_CPU, 0), "hash correct after undefined accesses");
    }

    // --- Coexistence ------------------------------------------------------------
    {
        uint64_t lanes[25];
        keccak_kclr();
        for (unsigned i = 0; i < 25; i++) {
            lanes[i] = 0x0123456789ABCDEFull * (i + 1);
            keccak_kxor(lanes[i], i);
        }
        check(kat(&sha3_kats[1], SHA3_IMPL_MMIO_DMA, 0), "MMIO hash with a loaded coprocessor");
        int same = 1;
        for (unsigned i = 0; i < 25; i++) same &= (keccak_krd(i) == lanes[i]);
        check(same, "coprocessor state unchanged by an MMIO hash");

        keccak_mmio_clear(144);  // SHA3-224 rate: 18 absorb lanes
        for (unsigned i = 0; i < 18; i++) keccak_mmio_absorb(i, lanes[i]);
        check(kat(&sha3_kats[1], SHA3_IMPL_ISE_KPERM, 0), "ISE hash with a loaded accelerator");
        same = 1;
        for (unsigned i = 0; i < 25; i++) same &= (keccak_mmio_read(i) == (i < 18 ? lanes[i] : 0));
        check(same, "accelerator state unchanged by an ISE hash");
    }

    printf("sha3_kat_mmio: %s (%d failures)\r\n", fails ? "FAIL" : "PASS", fails);
    newt_uart_flush();
    return newt_exit_code(fails);
}
