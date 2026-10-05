// Copyright 2026 Kyiv School of Economics.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Testbench-only wrapper: exposes keccak_cvxif's CV-X-IF structs as flat
// ports so the C++ harness does not depend on the packed struct layout.
// With KECCAK_GL defined it drives the gate-level model instead of the RTL.
// Drives the request fields CVA6's cvxif_fu drives (issue + commit in the
// same cycle, result always ready unless the harness says otherwise).

module keccak_cvxif_tb_top #(
  parameter int unsigned RoundsPerCycle = 1
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  // issue
  input  logic        issue_valid_i,
  input  logic [31:0] issue_instr_i,
  input  logic [7:0]  issue_id_i,   // zero-extended; X_ID_WIDTH bits used
  input  logic [63:0] issue_rs1_i,
  input  logic [63:0] issue_rs2_i,
  output logic        issue_ready_o,
  output logic        issue_accept_o,
  output logic        issue_writeback_o,
  // result
  input  logic        result_ready_i,
  output logic        result_valid_o,
  output logic [7:0]  result_id_o,
  output logic [63:0] result_data_o,
  output logic [4:0]  result_rd_o,
  output logic        result_we_o,
  output logic        result_exc_o,
  output logic [5:0]  result_exccode_o
);

  cvxif_pkg::cvxif_req_t  cvxif_req;
  cvxif_pkg::cvxif_resp_t cvxif_resp;

  always_comb begin
    cvxif_req                          = '0;
    cvxif_req.x_issue_valid            = issue_valid_i;
    cvxif_req.x_issue_req.instr        = issue_instr_i;
    cvxif_req.x_issue_req.mode         = 2'b11;
    cvxif_req.x_issue_req.id           = issue_id_i[cvxif_pkg::X_ID_WIDTH-1:0];
    cvxif_req.x_issue_req.rs[0]        = issue_rs1_i;
    cvxif_req.x_issue_req.rs[1]        = issue_rs2_i;
    cvxif_req.x_issue_req.rs_valid     = '1;
    cvxif_req.x_commit_valid           = issue_valid_i;
    cvxif_req.x_commit.id              = issue_id_i[cvxif_pkg::X_ID_WIDTH-1:0];
    cvxif_req.x_commit.x_commit_kill   = 1'b0;
    cvxif_req.x_result_ready           = result_ready_i;
  end

`ifdef KECCAK_GL
  // Gate-level model of the synthesized block (block-synth.mk power flow):
  // keccak_cvxif_gl wraps the netlist's bit-blasted ports. RoundsPerCycle is
  // fixed by the netlist, so the parameter only has to match it.
  keccak_cvxif_gl i_dut (
    .clk_i,
    .rst_ni,
    .cvxif_req_i  ( cvxif_req  ),
    .cvxif_resp_o ( cvxif_resp )
  );
`else
  keccak_cvxif #(
    .RoundsPerCycle ( RoundsPerCycle )
  ) i_dut (
    .clk_i,
    .rst_ni,
    .cvxif_req_i  ( cvxif_req  ),
    .cvxif_resp_o ( cvxif_resp )
  );
`endif

  // Interfaces the harness does not observe (compressed, issue-resp flags
  // other than accept/writeback, memory) and the unused high id bits.
  logic unused_signals;
  assign unused_signals = ^{issue_id_i[7:cvxif_pkg::X_ID_WIDTH], cvxif_resp.x_compressed_ready,
                            cvxif_resp.x_compressed_resp, cvxif_resp.x_issue_resp.dualwrite,
                            cvxif_resp.x_issue_resp.dualread, cvxif_resp.x_issue_resp.loadstore,
                            cvxif_resp.x_issue_resp.exc, cvxif_resp.x_mem_valid,
                            cvxif_resp.x_mem_req};

  assign issue_ready_o     = cvxif_resp.x_issue_ready;
  assign issue_accept_o    = cvxif_resp.x_issue_resp.accept;
  assign issue_writeback_o = cvxif_resp.x_issue_resp.writeback;
  assign result_valid_o    = cvxif_resp.x_result_valid;
  assign result_id_o       = 8'(cvxif_resp.x_result.id);
  assign result_data_o     = cvxif_resp.x_result.data;
  assign result_rd_o       = cvxif_resp.x_result.rd;
  assign result_we_o       = cvxif_resp.x_result.we;
  assign result_exc_o      = cvxif_resp.x_result.exc;
  assign result_exccode_o  = cvxif_resp.x_result.exccode;

endmodule
