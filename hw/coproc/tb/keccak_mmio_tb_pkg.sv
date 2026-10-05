// Copyright 2026 Kyiv School of Economics.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// AXI types for the keccak_mmio testbenches, laid out like the SoC's external
// slave port (iguana_soc: 48-bit address, 64-bit data, ID width 5, user width
// 2) and like block-synth.mk's synthesis wrapper, so the gate-level model's
// bit-blasted ports line up with these structs (power flow, task 8.1).

`include "axi/typedef.svh"

package keccak_mmio_tb_pkg;
  typedef logic [47:0] addr_t;
  typedef logic [63:0] data_t;
  typedef logic [7:0]  strb_t;
  typedef logic [4:0]  id_t;
  typedef logic [1:0]  user_t;
  `AXI_TYPEDEF_ALL(axi, addr_t, id_t, data_t, strb_t, user_t)
endpackage
