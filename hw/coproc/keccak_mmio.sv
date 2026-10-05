// Copyright 2026 Kyiv School of Economics.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Memory-mapped Keccak-f[1600] accelerator: the SHA-3 comparison arm of the
// Keccak ISE (openspec change sha3-cvxif-coprocessor, spec
// keccak-mmio-accelerator, design D6). An AXI subordinate on Cheshire's
// external port, behind axi_to_detailed_mem; no AXI manager. Software feeds it
// with CPU stores, or with Cheshire's iDMA copying a rate block into the
// absorb window.
//
// Register map (byte offsets in the 4 KiB region, 64-bit registers):
//
//   0x000  CTRL    W  bit 0 CLEAR: state := 0, DONE := 0
//                     bit 1 START: run Keccak-f[1600] (24 rounds), DONE := 0
//                     bits 3:2 RATE: absorb lanes 18 / 17 / 13 / 9 for
//                     SHA3-224 / -256 / -384 / -512 (reset: SHA3-256)
//                  R  bits 3:2 RATE, others 0
//   0x008  STATUS  R  bit 0 BUSY (permutation running), bit 1 DONE (a
//                     permutation finished since the last CLEAR/START)
//   0x100 + 8*i    W  ABSORB lane i (i < the rate's lane count): lane i ^= data,
//                     honouring byte strobes
//   0x200 + 8*i    R  STATE lane i (i < 25)
//
// Any other offset or direction completes with SLVERR and changes nothing.
// Accesses are 64-bit words: axi_to_detailed_mem aligns the address, so a
// narrow access reaches its word and selects bytes with the write strobes.
// While BUSY, writes and STATE reads are held off (the memory grant is
// withheld) until the permutation ends, so neither software nor the iDMA needs
// flow control of its own; STATUS stays readable for polling. CLEAR and START
// together act as CLEAR followed by START.
//
// The round datapath is the coprocessor's: RoundsPerCycle chained
// keccak_round instances, so the two arms differ only in how they are reached.

`include "common_cells/assertions.svh"

module keccak_mmio
  import keccak_pkg::*;
#(
  // Keccak rounds per cycle; must divide 24 (1, 2, 3, 4, 6 supported).
  parameter int unsigned RoundsPerCycle = 1,
  parameter int unsigned AddrWidth      = 48,
  parameter int unsigned DataWidth      = 64,
  parameter int unsigned IdWidth        = 1,
  parameter int unsigned UserWidth      = 1,
  parameter type         axi_req_t      = logic,
  parameter type         axi_rsp_t      = logic
) (
  input  logic     clk_i,
  // SYNCASYNCNET: the only synchronous use of rst_ni is the assertions'
  // `disable iff`, which Verilator counts as a synchronous read.
  // verilator lint_off SYNCASYNCNET
  input  logic     rst_ni,
  // verilator lint_on SYNCASYNCNET
  input  axi_req_t axi_req_i,
  output axi_rsp_t axi_rsp_o
);

  localparam int unsigned PermCycles = NumRounds / RoundsPerCycle;

  localparam logic [11:0] OffsetCtrl   = 12'h000;
  localparam logic [11:0] OffsetStatus = 12'h008;
  localparam logic [11:0] OffsetAbsorb = 12'h100;
  localparam logic [11:0] OffsetState  = 12'h200;

  typedef logic [AddrWidth-1:0]   addr_t;
  typedef logic [DataWidth-1:0]   data_t;
  typedef logic [DataWidth/8-1:0] strb_t;

  // Absorb lanes per rate select (SHA3-224, -256, -384, -512).
  function automatic logic [4:0] rate_lanes(logic [1:0] rate);
    unique case (rate)
      2'd0:    return 5'd18;
      2'd1:    return 5'd17;
      2'd2:    return 5'd13;
      2'd3:    return 5'd9;
      default: return 5'd17;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // AXI to memory requests
  // ---------------------------------------------------------------------------

  logic  mem_req, mem_gnt, mem_we, mem_rvalid, mem_err;
  addr_t mem_addr;
  data_t mem_wdata, mem_rdata;
  strb_t mem_strb;
  logic  axi_busy;

  // Request attributes this subordinate does not use.
  axi_pkg::atop_t       mem_atop;
  axi_pkg::cache_t      mem_cache;
  axi_pkg::prot_t       mem_prot;
  axi_pkg::qos_t        mem_qos;
  axi_pkg::region_t     mem_region;
  logic                 mem_lock;
  logic [IdWidth-1:0]   mem_id;
  logic [UserWidth-1:0] mem_user;

  axi_to_detailed_mem #(
    .axi_req_t    ( axi_req_t ),
    .axi_resp_t   ( axi_rsp_t ),
    .AddrWidth    ( AddrWidth ),
    .DataWidth    ( DataWidth ),
    .IdWidth      ( IdWidth   ),
    .UserWidth    ( UserWidth ),
    .NumBanks     ( 1         ),
    .BufDepth     ( 1         ),
    .HideStrb     ( 1'b0      ),
    .OutFifoDepth ( 1         )
  ) i_axi_to_mem (
    .clk_i,
    .rst_ni,
    .busy_o       ( axi_busy   ),
    .axi_req_i,
    .axi_resp_o   ( axi_rsp_o  ),
    .mem_req_o    ( mem_req    ),
    .mem_gnt_i    ( mem_gnt    ),
    .mem_addr_o   ( mem_addr   ),
    .mem_wdata_o  ( mem_wdata  ),
    .mem_strb_o   ( mem_strb   ),
    .mem_atop_o   ( mem_atop   ),
    .mem_lock_o   ( mem_lock   ),
    .mem_we_o     ( mem_we     ),
    .mem_id_o     ( mem_id     ),
    .mem_user_o   ( mem_user   ),
    .mem_cache_o  ( mem_cache  ),
    .mem_prot_o   ( mem_prot   ),
    .mem_qos_o    ( mem_qos    ),
    .mem_region_o ( mem_region ),
    .mem_rvalid_i ( mem_rvalid ),
    .mem_rdata_i  ( mem_rdata  ),
    .mem_err_i    ( mem_err    ),
    .mem_exokay_i ( 1'b0       )
  );

  logic unused_request;
  assign unused_request = ^{axi_busy, mem_atop, mem_lock, mem_id, mem_user, mem_cache, mem_prot,
                            mem_qos, mem_region, mem_addr[AddrWidth-1:12], mem_addr[2:0]};

  // ---------------------------------------------------------------------------
  // Decode
  // ---------------------------------------------------------------------------

  logic [11:0] offset;
  logic [4:0]  lane;
  logic        is_ctrl, is_status, is_absorb, is_state;
  logic        legal, holds_while_busy;
  logic        busy_q, done_q;
  logic [1:0]  rate_q;

  assign offset    = {mem_addr[11:3], 3'b000};
  assign lane      = offset[7:3];
  assign is_ctrl   = (offset == OffsetCtrl);
  assign is_status = (offset == OffsetStatus);
  assign is_absorb = (offset[11:8] == OffsetAbsorb[11:8]) && (lane < rate_lanes(rate_q));
  assign is_state  = (offset[11:8] == OffsetState[11:8]) && (lane < 5'(NumLanes));

  assign legal = mem_we ? (is_ctrl || is_absorb) : (is_ctrl || is_status || is_state);
  // Everything but a STATUS read waits for a running permutation to end.
  assign holds_while_busy = !(!mem_we && is_status);
  assign mem_gnt = mem_req && !(busy_q && holds_while_busy);

  // A granted access that applies (as opposed to one answered with SLVERR).
  logic access;
  assign access = mem_gnt && legal;

  // ---------------------------------------------------------------------------
  // State and permutation
  // ---------------------------------------------------------------------------

  state_t                          state_d, state_q;
  logic                            busy_d, done_d;
  logic [1:0]                      rate_d;
  logic [$clog2(PermCycles+1)-1:0] perm_count_d, perm_count_q;

  state_t [RoundsPerCycle:0]  round_state;
  lane_t  [RoundsPerCycle-1:0] stage_round_constant;

  assign round_state[0] = state_q;

  for (genvar j = 0; j < RoundsPerCycle; j++) begin : gen_rounds
    assign stage_round_constant[j] =
        round_constant(round_idx_t'(32'(perm_count_q) * RoundsPerCycle + j));

    keccak_round i_keccak_round (
      .state_i          ( round_state[j]          ),
      .round_constant_i ( stage_round_constant[j] ),
      .state_o          ( round_state[j + 1]      )
    );
  end

  // Byte-strobe merge for absorb writes.
  data_t strb_mask;
  for (genvar b = 0; b < DataWidth / 8; b++) begin : gen_strb_mask
    assign strb_mask[8*b +: 8] = {8{mem_strb[b]}};
  end

  always_comb begin : next_state_logic
    state_d      = state_q;
    busy_d       = busy_q;
    done_d       = done_q;
    rate_d       = rate_q;
    perm_count_d = perm_count_q;

    if (busy_q) begin
      state_d      = round_state[RoundsPerCycle];
      perm_count_d = perm_count_q + 1'b1;
      if (perm_count_q == ($bits(perm_count_q))'(PermCycles - 1)) begin
        busy_d = 1'b0;
        done_d = 1'b1;
      end
    end else if (access && mem_we) begin
      if (is_ctrl) begin
        rate_d = mem_strb[0] ? mem_wdata[3:2] : rate_q;
        if (mem_strb[0] && mem_wdata[0]) begin
          state_d = '0;
          done_d  = 1'b0;
        end
        if (mem_strb[0] && mem_wdata[1]) begin
          busy_d       = 1'b1;
          done_d       = 1'b0;
          perm_count_d = '0;
        end
      end else begin
        state_d[lane] = state_q[lane] ^ (mem_wdata & strb_mask);
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : sequential_logic
    if (!rst_ni) begin
      state_q      <= '0;
      busy_q       <= 1'b0;
      done_q       <= 1'b0;
      rate_q       <= 2'd1;  // SHA3-256
      perm_count_q <= '0;
    end else begin
      state_q      <= state_d;
      busy_q       <= busy_d;
      done_q       <= done_d;
      rate_q       <= rate_d;
      perm_count_q <= perm_count_d;
    end
  end

  // ---------------------------------------------------------------------------
  // Response: one cycle after the grant, reads and writes alike
  // ---------------------------------------------------------------------------

  data_t rdata_d;

  always_comb begin : read_data_logic
    rdata_d = '0;
    if (!mem_we) begin
      if (is_ctrl) begin
        rdata_d[3:2] = rate_q;
      end else if (is_status) begin
        rdata_d[1:0] = {done_q, busy_q};
      end else if (is_state) begin
        rdata_d = state_q[lane];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : response_logic
    if (!rst_ni) begin
      mem_rvalid <= 1'b0;
      mem_err    <= 1'b0;
      mem_rdata  <= '0;
    end else begin
      mem_rvalid <= mem_gnt;
      mem_err    <= mem_gnt && !legal;
      mem_rdata  <= (mem_gnt && legal) ? rdata_d : '0;
    end
  end

  // ---------------------------------------------------------------------------
  // Assertions
  // ---------------------------------------------------------------------------

  `ASSERT_INIT(RoundsPerCycleDividesRounds_A,
               (RoundsPerCycle >= 1) && (RoundsPerCycle <= 6) &&
               (NumRounds % RoundsPerCycle == 0))
  `ASSERT_INIT(DataWidthIsLane_A, DataWidth == 64)

  // Nothing but a STATUS read is granted while a permutation runs.
  `ASSERT(NoAccessWhileBusy_A, busy_q && mem_gnt |-> !mem_we && is_status, clk_i, !rst_ni)

endmodule
