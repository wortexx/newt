// Copyright 2026 Kyiv School of Economics.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Keccak-f[1600] CV-X-IF coprocessor for CVA6 (pre-1.0 CV-X-IF, cvxif_pkg).
//
// Holds one 1600-bit Keccak state and executes five R-type instructions on
// the custom-1 opcode (0b0101011), funct7 = 0, selected by funct3:
//
//   funct3  mnemonic  operands                     writes rd
//   000     kclr      -                            no   state := 0
//   001     kxor      rs1 = data, rs2 = lane       no   state[lane] ^= rs1
//   010     krd       rs2 = lane                   yes  rd := state[lane]
//   011     shatr     rs1 = round index (0..23)    no   one Keccak-f round
//   100     kperm     -                            no   full 24-round Keccak-f
//
// Encoding rules (spec keccak-coprocessor):
// - any other funct3 or a non-zero funct7 is not accepted, so CVA6 raises an
//   illegal-instruction exception;
// - a non-writing instruction must have rd = x0. The pinned CVA6 forwards a
//   non-writing offload's result to a reader of its rd in the writeback cycle
//   (design D3), so rd != x0 is not accepted either;
// - a lane index >= 25 or a round index >= 24 (register values) completes
//   with an illegal-instruction exception and leaves the state unchanged.
//
// Microarchitecture (design D3): accepted instructions enter an in-order
// issue queue and execute one at a time from its head. kclr/kxor/krd/shatr
// execute in one cycle and present a registered result in the next cycle;
// kperm runs NumRounds / RoundsPerCycle cycles through RoundsPerCycle
// chained rounds. Results are always registered, so neither the lane
// multiplexer nor the round logic sits on CVA6's issue-to-writeback path.
//
// Why a queue: CVA6's issue stage decides to dispatch from x_issue_ready in
// cycle t but drives x_issue_valid in cycle t+1, as a one-cycle pulse it
// never repeats. If x_issue_ready is low in t+1 the instruction is lost and
// the core waits forever for its result (two back-to-back coprocessor
// instructions did exactly that when this block held one instruction at a
// time). The queue is as deep as CVA6's scoreboard: every offloaded
// instruction holds a scoreboard entry until its result is written back, so
// at most NR_SB_ENTRIES are ever outstanding and x_issue_ready stays high.
// With fall-through, an instruction reaching an empty queue and an idle
// datapath starts executing in its issue cycle, as before.
//
// The commit interface is ignored: this CVA6 never kills an offloaded
// instruction (x_commit_kill is tied to 0). The memory interface is unused.

`include "common_cells/assertions.svh"

module keccak_cvxif
  import keccak_pkg::*;
#(
  // Keccak rounds per kperm cycle; must divide 24 (1, 2, 3, 4, 6 supported).
  parameter int unsigned RoundsPerCycle = 1
) (
  input  logic                   clk_i,
  // SYNCASYNCNET: the only synchronous use of rst_ni is the assertions'
  // `disable iff`, which Verilator counts as a synchronous read.
  // verilator lint_off SYNCASYNCNET
  input  logic                   rst_ni,
  // verilator lint_on SYNCASYNCNET
  input  cvxif_pkg::cvxif_req_t  cvxif_req_i,
  output cvxif_pkg::cvxif_resp_t cvxif_resp_o
);

  localparam int unsigned PermCycles = NumRounds / RoundsPerCycle;

  localparam logic [6:0] OpcodeCustom1 = 7'b0101011;

  typedef enum logic [2:0] {
    OP_KCLR  = 3'b000,
    OP_KXOR  = 3'b001,
    OP_KRD   = 3'b010,
    OP_SHATR = 3'b011,
    OP_KPERM = 3'b100
  } keccak_op_e;

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_PERM,
    ST_RESULT
  } fsm_state_e;

  localparam logic [5:0] ExcIllegalInstr = 6'd2;

  // Outstanding offloads are bounded by CVA6's scoreboard (see header).
  localparam int unsigned IssueDepth = ariane_pkg::NR_SB_ENTRIES;

  // What execution needs from an accepted instruction. The lane index is
  // range-checked at issue (only its low bits are kept); the shatr round
  // index is the full rs1, which kxor needs as data anyway.
  typedef struct packed {
    keccak_op_e                       op;
    logic [cvxif_pkg::X_ID_WIDTH-1:0] id;
    logic [4:0]                       rd;
    riscv::xlen_t                     rs1;
    lane_idx_t                        lane;
    logic                             lane_ok;
  } issue_entry_t;

  // ---------------------------------------------------------------------------
  // Issue decode
  // ---------------------------------------------------------------------------

  logic [31:0]          instr;
  logic [2:0]           funct3;
  logic [6:0]           funct7;
  logic [4:0]           instr_rd;
  logic                 op_known;
  logic                 op_writes_rd;
  logic                 issue_accept;
  logic                 issue_push;
  riscv::xlen_t         operand_rs1;
  riscv::xlen_t         operand_rs2;

  assign instr        = cvxif_req_i.x_issue_req.instr;
  assign funct3       = instr[14:12];
  assign funct7       = instr[31:25];
  assign instr_rd     = instr[11:7];
  assign operand_rs1  = cvxif_req_i.x_issue_req.rs[0];
  assign operand_rs2  = cvxif_req_i.x_issue_req.rs[1];

  // Request fields this coprocessor does not use: the compressed, commit and
  // memory interfaces, the privilege mode, rs_valid (CVA6 always offers both
  // operands) and the register-number fields of the instruction (CVA6 has
  // already read the registers).
  logic unused_request;
  assign unused_request = ^{cvxif_req_i.x_compressed_valid, cvxif_req_i.x_compressed_req,
                            cvxif_req_i.x_issue_req.mode, cvxif_req_i.x_issue_req.rs_valid,
                            cvxif_req_i.x_commit_valid, cvxif_req_i.x_commit,
                            cvxif_req_i.x_mem_ready, cvxif_req_i.x_mem_resp,
                            cvxif_req_i.x_mem_result_valid, cvxif_req_i.x_mem_result,
                            instr[24:15]};

  assign op_known     = (funct3 <= OP_KPERM);
  assign op_writes_rd = (funct3 == OP_KRD);
  assign issue_accept = (instr[6:0] == OpcodeCustom1) && (funct7 == 7'b0) && op_known &&
                        (op_writes_rd || (instr_rd == 5'd0));

  // ---------------------------------------------------------------------------
  // Issue queue
  // ---------------------------------------------------------------------------

  issue_entry_t                           issue_entry, head;
  logic                                   queue_full, queue_empty;
  logic [$clog2(IssueDepth)-1:0]          queue_usage;
  logic                                   exec_fire;

  assign issue_entry = '{
    op:      keccak_op_e'(funct3),
    id:      cvxif_req_i.x_issue_req.id,
    rd:      instr_rd,
    rs1:     operand_rs1,
    lane:    lane_idx_t'(operand_rs2),
    lane_ok: (operand_rs2 < riscv::xlen_t'(NumLanes))
  };
  assign issue_push = cvxif_req_i.x_issue_valid && issue_accept;

  fifo_v3 #(
    .FALL_THROUGH ( 1'b1          ),
    .DEPTH        ( IssueDepth    ),
    .dtype        ( issue_entry_t )
  ) i_issue_queue (
    .clk_i,
    .rst_ni,
    .flush_i    ( 1'b0        ),
    .testmode_i ( 1'b0        ),
    .full_o     ( queue_full  ),
    .empty_o    ( queue_empty ),
    .usage_o    ( queue_usage ),
    .data_i     ( issue_entry ),
    .push_i     ( issue_push  ),
    .data_o     ( head        ),
    .pop_i      ( exec_fire   )
  );

  // The fill level is not needed: x_issue_ready is derived from full_o.
  logic unused_queue_usage;
  assign unused_queue_usage = ^queue_usage;

  // ---------------------------------------------------------------------------
  // State, FSM and result registers
  // ---------------------------------------------------------------------------

  fsm_state_e                  fsm_state_d, fsm_state_q;
  state_t                      state_d, state_q;
  logic [$clog2(PermCycles+1)-1:0] perm_count_d, perm_count_q;
  logic [cvxif_pkg::X_ID_WIDTH-1:0] result_id_d, result_id_q;
  logic [4:0]                  result_rd_d, result_rd_q;
  logic                        result_we_d, result_we_q;
  logic                        result_exc_d, result_exc_q;
  lane_t                       result_data_d, result_data_q;

  logic issue_ready;
  logic result_valid;

  assign issue_ready  = !queue_full;
  assign exec_fire    = !queue_empty && (fsm_state_q == ST_IDLE);
  assign result_valid = (fsm_state_q == ST_RESULT);

  // ---------------------------------------------------------------------------
  // Round datapath: RoundsPerCycle chained rounds. shatr uses the first stage
  // with the round constant of its operand; kperm uses all stages with the
  // constants of rounds perm_count*RoundsPerCycle + j.
  // ---------------------------------------------------------------------------

  state_t [RoundsPerCycle:0] round_state;
  lane_t  [RoundsPerCycle-1:0] stage_round_constant;
  logic                       shatr_issue;

  assign shatr_issue    = exec_fire && (head.op == OP_SHATR);
  assign round_state[0] = state_q;

  for (genvar j = 0; j < RoundsPerCycle; j++) begin : gen_rounds
    if (j == 0) begin : gen_first
      assign stage_round_constant[j] = shatr_issue ?
          round_constant_of(head.rs1) :
          round_constant_of(riscv::xlen_t'(perm_count_q) * RoundsPerCycle);
    end else begin : gen_chained
      assign stage_round_constant[j] =
          round_constant_of(riscv::xlen_t'(perm_count_q) * RoundsPerCycle + j);
    end

    keccak_round i_keccak_round (
      .state_i          ( round_state[j]     ),
      .round_constant_i ( stage_round_constant[j]  ),
      .state_o          ( round_state[j + 1] )
    );
  end

  // Round constant for a 64-bit round number; out-of-range numbers give 0
  // (shatr rejects them before the result is used).
  function automatic lane_t round_constant_of(riscv::xlen_t round_number);
    return (round_number < riscv::xlen_t'(NumRounds)) ?
        round_constant(round_idx_t'(round_number)) : '0;
  endfunction

  // ---------------------------------------------------------------------------
  // Next-state logic
  // ---------------------------------------------------------------------------

  always_comb begin
    fsm_state_d   = fsm_state_q;
    state_d       = state_q;
    perm_count_d  = perm_count_q;
    result_id_d   = result_id_q;
    result_rd_d   = result_rd_q;
    result_we_d   = result_we_q;
    result_exc_d  = result_exc_q;
    result_data_d = result_data_q;

    unique case (fsm_state_q)
      ST_IDLE: begin
        if (exec_fire) begin
          result_id_d   = head.id;
          result_rd_d   = head.rd;
          result_we_d   = 1'b0;
          result_exc_d  = 1'b0;
          result_data_d = '0;
          fsm_state_d   = ST_RESULT;

          unique case (head.op)
            OP_KCLR: begin
              state_d = '0;
            end
            OP_KXOR: begin
              if (head.lane_ok) begin
                state_d[head.lane] = state_q[head.lane] ^ head.rs1;
              end else begin
                result_exc_d = 1'b1;
              end
            end
            OP_KRD: begin
              if (head.lane_ok) begin
                result_data_d = state_q[head.lane];
                result_we_d   = 1'b1;
              end else begin
                result_exc_d = 1'b1;
              end
            end
            OP_SHATR: begin
              if (head.rs1 < riscv::xlen_t'(NumRounds)) begin
                state_d = round_state[1];
              end else begin
                result_exc_d = 1'b1;
              end
            end
            OP_KPERM: begin
              perm_count_d = '0;
              fsm_state_d  = ST_PERM;
            end
            default: begin
              // Not reachable: only accepted (known) ops enter the queue.
              result_exc_d = 1'b1;
            end
          endcase
        end
      end

      ST_PERM: begin
        state_d      = round_state[RoundsPerCycle];
        perm_count_d = perm_count_q + 1'b1;
        if (perm_count_q == ($bits(perm_count_q))'(PermCycles - 1)) begin
          fsm_state_d = ST_RESULT;
        end
      end

      ST_RESULT: begin
        if (cvxif_req_i.x_result_ready) begin
          fsm_state_d = ST_IDLE;
        end
      end

      default: begin
        fsm_state_d = ST_IDLE;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fsm_state_q   <= ST_IDLE;
      state_q       <= '0;
      perm_count_q  <= '0;
      result_id_q   <= '0;
      result_rd_q   <= '0;
      result_we_q   <= 1'b0;
      result_exc_q  <= 1'b0;
      result_data_q <= '0;
    end else begin
      fsm_state_q   <= fsm_state_d;
      state_q       <= state_d;
      perm_count_q  <= perm_count_d;
      result_id_q   <= result_id_d;
      result_rd_q   <= result_rd_d;
      result_we_q   <= result_we_d;
      result_exc_q  <= result_exc_d;
      result_data_q <= result_data_d;
    end
  end

  // ---------------------------------------------------------------------------
  // CV-X-IF response
  // ---------------------------------------------------------------------------

  always_comb begin
    cvxif_resp_o = '0;

    // Compressed interface: not used.
    cvxif_resp_o.x_compressed_ready = 1'b0;

    // Issue interface. accept/writeback are a function of the offered
    // instruction only; CVA6 samples them together with x_issue_valid and
    // x_issue_ready. x_issue_ready is high unless the queue is full, which
    // the scoreboard bound rules out (IssueQueueReady_A).
    cvxif_resp_o.x_issue_ready            = issue_ready;
    cvxif_resp_o.x_issue_resp.accept      = issue_accept;
    cvxif_resp_o.x_issue_resp.writeback   = issue_accept && op_writes_rd;
    cvxif_resp_o.x_issue_resp.dualwrite   = 1'b0;
    cvxif_resp_o.x_issue_resp.dualread    = 1'b0;
    cvxif_resp_o.x_issue_resp.loadstore   = 1'b0;
    cvxif_resp_o.x_issue_resp.exc         = 1'b0;

    // Memory interface: not used.
    cvxif_resp_o.x_mem_valid = 1'b0;

    // Result interface.
    cvxif_resp_o.x_result_valid   = result_valid;
    cvxif_resp_o.x_result.id      = result_id_q;
    cvxif_resp_o.x_result.data    = result_data_q;
    cvxif_resp_o.x_result.rd      = result_rd_q;
    cvxif_resp_o.x_result.we      = result_valid && result_we_q && !result_exc_q;
    cvxif_resp_o.x_result.exc     = result_valid && result_exc_q;
    cvxif_resp_o.x_result.exccode = result_exc_q ? ExcIllegalInstr : 6'd0;
  end

  // ---------------------------------------------------------------------------
  // Assertions
  // ---------------------------------------------------------------------------

  `ASSERT_INIT(RoundsPerCycleDividesRounds_A,
               (RoundsPerCycle >= 1) && (RoundsPerCycle <= 6) &&
               (NumRounds % RoundsPerCycle == 0))

  // A result is held until the core takes it.
  `ASSERT(ResultHeldUntilReady_A,
          result_valid && !cvxif_req_i.x_result_ready |=> result_valid &&
          $stable(cvxif_resp_o.x_result), clk_i, !rst_ni)

  // Only krd ever requests a register write.
  `ASSERT(OnlyKrdWrites_A,
          exec_fire && (head.op != OP_KRD) |=> !result_we_q, clk_i, !rst_ni)

  // CVA6 never retries an offload, so every one must find the queue ready:
  // a lost instruction would leave the core waiting forever.
  `ASSERT(IssueQueueReady_A, cvxif_req_i.x_issue_valid |-> issue_ready, clk_i, !rst_ni)

endmodule
