// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Known-answer test for the software baselines (spec sha3-evaluation,
// "Known-answer correctness gate"): every vector of
// sw/vectors/sha3_kat_vectors.h through the riscv-crypto reference, XKCP
// ref-64bits and XKCP opt64 back-ends on the SoC. Exits non-zero on the first
// mismatch, naming variant, implementation and vector.

#include "newt_test.h"
#include "sha3.h"
#include "sha3_kat_vectors.h"

int main(void) {
    newt_uart_init();
    set_mie(0);
    printf("sha3_kat_sw: %u vectors x %u implementations\r\n", SHA3_NUM_KATS,
           (unsigned)(SHA3_NUM_IMPLS - SHA3_FIRST_SW));

    for (unsigned impl = SHA3_FIRST_SW; impl < SHA3_NUM_IMPLS; impl++) {
        for (unsigned k = 0; k < SHA3_NUM_KATS; k++) {
            const sha3_kat_t *t = &sha3_kats[k];
            unsigned n = sha3_digest_bytes(t->variant);
            uint8_t d[64];
            sha3_hash(t->variant, (sha3_impl_t)impl, t->msg, t->len, d);
            int ok = 1;
            for (unsigned b = 0; b < n; b++) ok &= (d[b] == t->md[b]);
            if (!ok) {
                printf("FAIL %s %s vector %u (len %u): digest mismatch\r\n",
                       sha3_variant_name(t->variant), sha3_impl_name((sha3_impl_t)impl), k,
                       (unsigned)t->len);
                newt_uart_flush();
                return newt_exit_code(1);
            }
        }
        printf("sha3_kat_sw: %s passes all %u vectors\r\n", sha3_impl_name((sha3_impl_t)impl),
               SHA3_NUM_KATS);
    }
    printf("sha3_kat_sw: PASS (0 failures)\r\n");
    newt_uart_flush();
    return 0;
}
