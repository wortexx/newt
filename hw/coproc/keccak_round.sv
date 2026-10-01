// Copyright 2026 Kyiv School of Economics.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// One combinational round of Keccak-f[1600] (FIPS 202, Algorithm 7):
// theta, rho, pi, chi, iota. The round constant is an input, so the same
// block serves any round index and can be chained R times for an unrolled
// permutation. Lane indexing as in keccak_pkg: i = x + 5*y.

module keccak_round
  import keccak_pkg::*;
(
  input  state_t state_i,
  input  lane_t  round_constant_i,
  output state_t state_o
);

  // rho rotation offsets r[x, y], indexed by lane i = x + 5*y.
  localparam int unsigned RhoOffsets [NumLanes] = '{
     0,  1, 62, 28, 27,
    36, 44,  6, 55, 20,
     3, 10, 43, 25, 39,
    41, 45, 15, 21,  8,
    18,  2, 61, 56, 14
  };

  function automatic lane_t rotate_left(lane_t value, int unsigned amount);
    return (amount == 0) ? value : ((value << amount) | (value >> (LaneWidth - amount)));
  endfunction

  lane_t [4:0] column_parity;
  lane_t [4:0] theta_effect;
  state_t      theta_state;
  state_t      pi_state;
  state_t      chi_state;

  // theta: C[x] = xor over y of A[x, y]; D[x] = C[x-1] ^ rot(C[x+1], 1);
  // A[x, y] ^= D[x].
  always_comb begin
    for (int unsigned x = 0; x < 5; x++) begin
      column_parity[x] = state_i[x] ^ state_i[x + 5] ^ state_i[x + 10] ^
                         state_i[x + 15] ^ state_i[x + 20];
    end
    for (int unsigned x = 0; x < 5; x++) begin
      theta_effect[x] = column_parity[(x + 4) % 5] ^
                        rotate_left(column_parity[(x + 1) % 5], 1);
    end
    for (int unsigned i = 0; i < NumLanes; i++) begin
      theta_state[i] = state_i[i] ^ theta_effect[i % 5];
    end
  end

  // rho and pi: B[y, 2x + 3y] = rot(A[x, y], r[x, y]).
  always_comb begin
    for (int unsigned x = 0; x < 5; x++) begin
      for (int unsigned y = 0; y < 5; y++) begin
        pi_state[y + 5 * ((2 * x + 3 * y) % 5)] =
            rotate_left(theta_state[x + 5 * y], RhoOffsets[x + 5 * y]);
      end
    end
  end

  // chi: A[x, y] = B[x, y] ^ (~B[x+1, y] & B[x+2, y]).
  always_comb begin
    for (int unsigned x = 0; x < 5; x++) begin
      for (int unsigned y = 0; y < 5; y++) begin
        chi_state[x + 5 * y] = pi_state[x + 5 * y] ^
                               (~pi_state[(x + 1) % 5 + 5 * y] & pi_state[(x + 2) % 5 + 5 * y]);
      end
    end
  end

  // iota: lane (0, 0) ^= RC.
  always_comb begin
    state_o    = chi_state;
    state_o[0] = chi_state[0] ^ round_constant_i;
  end

endmodule
