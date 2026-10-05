// Copyright 2026 Kyiv School of Economics.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Build smoke test for sw/lib/sha3.c: SHA3-256("abc") on both ISE back-ends
// (FIPS 202 example value). The full known-answer suite is sha3_kat_ise.

#include "newt_test.h"
#include "sha3.h"

static const uint8_t kAbc256[32] = {
    0x3a, 0x98, 0x5d, 0xa7, 0x4f, 0xe2, 0x25, 0xb2, 0x04, 0x5c, 0x17, 0x2d, 0x6b, 0xd3, 0x90, 0xbd,
    0x85, 0x5f, 0x08, 0x6e, 0x3e, 0x9d, 0x52, 0x5b, 0x46, 0xbf, 0xe2, 0x45, 0x11, 0x43, 0x15, 0x32};

int main(void) {
    newt_uart_init();
    set_mie(0);
    const uint8_t msg[3] = {'a', 'b', 'c'};
    for (unsigned impl = SHA3_FIRST_ISE; impl < SHA3_FIRST_SW; impl++) {
        uint8_t d[32];
        sha3_hash(SHA3_256, (sha3_impl_t)impl, msg, sizeof(msg), d);
        int ok = 1;
        for (unsigned k = 0; k < 32; k++) ok &= (d[k] == kAbc256[k]);
        NEWT_CHECK(ok, "SHA3-256(abc) on %s", sha3_impl_name((sha3_impl_t)impl));
    }
    printf("sha3_smoke: %s (%d failures)\r\n", newt_fails ? "FAIL" : "PASS", newt_fails);
    newt_uart_flush();
    return newt_exit_code(newt_fails);
}
