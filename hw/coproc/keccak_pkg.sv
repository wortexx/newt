// Copyright 2026 Kyiv School of Economics.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Shared definitions for the Keccak-f[1600] datapath used by the CV-X-IF
// coprocessor (keccak_cvxif) and the memory-mapped accelerator (keccak_mmio).
//
// State layout follows FIPS 202: lane i (0..24) holds coordinates
// x = i mod 5, y = i div 5, and byte k of lane i is state byte 8*i + k
// (little-endian lanes).

package keccak_pkg;

  localparam int unsigned NumLanes  = 25;
  localparam int unsigned LaneWidth = 64;
  localparam int unsigned NumRounds = 24;

  typedef logic [LaneWidth-1:0]               lane_t;
  typedef lane_t [NumLanes-1:0]               state_t;
  typedef logic [$clog2(NumRounds)-1:0]       round_idx_t;
  typedef logic [$clog2(NumLanes)-1:0]        lane_idx_t;

  // FIPS 202 iota round constants RC[0..23].
  localparam lane_t [NumRounds-1:0] RoundConstants = '{
    64'h8000_0000_8000_8008, 64'h0000_0000_8000_0001, 64'h8000_0000_0000_8080,
    64'h8000_0000_8000_8081, 64'h8000_0000_8000_000A, 64'h0000_0000_0000_800A,
    64'h8000_0000_0000_0080, 64'h8000_0000_0000_8002, 64'h8000_0000_0000_8003,
    64'h8000_0000_0000_8089, 64'h8000_0000_0000_008B, 64'h0000_0000_8000_808B,
    64'h0000_0000_8000_000A, 64'h0000_0000_8000_8009, 64'h0000_0000_0000_0088,
    64'h0000_0000_0000_008A, 64'h8000_0000_0000_8009, 64'h8000_0000_8000_8081,
    64'h0000_0000_8000_0001, 64'h0000_0000_0000_808B, 64'h8000_0000_8000_8000,
    64'h8000_0000_0000_808A, 64'h0000_0000_0000_8082, 64'h0000_0000_0000_0001
  };

  // Round constant for round `idx`. Indices >= NumRounds return 0 (callers
  // reject such indices before using the result).
  function automatic lane_t round_constant(round_idx_t idx);
    return (idx < round_idx_t'(NumRounds)) ? RoundConstants[idx] : '0;
  endfunction

endpackage
