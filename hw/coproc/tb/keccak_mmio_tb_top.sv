// Copyright 2026 Kyiv School of Economics.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Testbench-only wrapper: exposes keccak_mmio's AXI subordinate port as flat
// single-beat channels so the C++ harness acts as the AXI manager without
// depending on the packed struct layout. Widths match Cheshire's external
// subordinate port (48-bit address, 64-bit data, 2-bit user); the id is 4 bits.

`include "axi/typedef.svh"

module keccak_mmio_tb_top #(
  parameter int unsigned RoundsPerCycle = 1
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  // write address / data / response
  input  logic        aw_valid_i,
  output logic        aw_ready_o,
  input  logic [47:0] aw_addr_i,
  input  logic [7:0]  aw_len_i,
  input  logic        w_valid_i,
  output logic        w_ready_o,
  input  logic [63:0] w_data_i,
  input  logic [7:0]  w_strb_i,
  input  logic        w_last_i,
  output logic        b_valid_o,
  input  logic        b_ready_i,
  output logic [1:0]  b_resp_o,
  // read address / data
  input  logic        ar_valid_i,
  output logic        ar_ready_o,
  input  logic [47:0] ar_addr_i,
  output logic        r_valid_o,
  input  logic        r_ready_i,
  output logic [63:0] r_data_o,
  output logic [1:0]  r_resp_o,
  output logic        r_last_o
);

  typedef logic [47:0] addr_t;
  typedef logic [63:0] data_t;
  typedef logic [7:0]  strb_t;
  typedef logic [3:0]  id_t;
  typedef logic [1:0]  user_t;
  `AXI_TYPEDEF_ALL(axi, addr_t, id_t, data_t, strb_t, user_t)

  axi_req_t  axi_req;
  axi_resp_t axi_rsp;

  always_comb begin
    axi_req          = '0;
    axi_req.aw_valid = aw_valid_i;
    axi_req.aw.addr  = aw_addr_i;
    axi_req.aw.len   = aw_len_i;  // beats - 1 (iDMA-style INCR bursts)
    axi_req.aw.size  = 3'd3;      // 8-byte beats
    axi_req.aw.burst = axi_pkg::BURST_INCR;
    axi_req.w_valid  = w_valid_i;
    axi_req.w.data   = w_data_i;
    axi_req.w.strb   = w_strb_i;
    axi_req.w.last   = w_last_i;
    axi_req.b_ready  = b_ready_i;
    axi_req.ar_valid = ar_valid_i;
    axi_req.ar.addr  = ar_addr_i;
    axi_req.ar.size  = 3'd3;
    axi_req.ar.burst = axi_pkg::BURST_INCR;
    axi_req.r_ready  = r_ready_i;
  end

  keccak_mmio #(
    .RoundsPerCycle ( RoundsPerCycle ),
    .AddrWidth      ( 48             ),
    .DataWidth      ( 64             ),
    .IdWidth        ( 4              ),
    .UserWidth      ( 2              ),
    .axi_req_t      ( axi_req_t      ),
    .axi_rsp_t      ( axi_resp_t     )
  ) i_dut (
    .clk_i,
    .rst_ni,
    .axi_req_i ( axi_req ),
    .axi_rsp_o ( axi_rsp )
  );

  assign aw_ready_o = axi_rsp.aw_ready;
  assign w_ready_o  = axi_rsp.w_ready;
  assign b_valid_o  = axi_rsp.b_valid;
  assign b_resp_o   = axi_rsp.b.resp;
  assign ar_ready_o = axi_rsp.ar_ready;
  assign r_valid_o  = axi_rsp.r_valid;
  assign r_data_o   = axi_rsp.r.data;
  assign r_resp_o   = axi_rsp.r.resp;
  assign r_last_o   = axi_rsp.r.last;

  // Response fields the harness does not observe.
  logic unused_rsp;
  assign unused_rsp = ^{axi_rsp.b.id, axi_rsp.b.user, axi_rsp.r.id, axi_rsp.r.user};

endmodule
