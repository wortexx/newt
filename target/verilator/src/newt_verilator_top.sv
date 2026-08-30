// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Top-level harness (for Verilator) of the open-source (Questa-free)
// simulation lane. Wraps `iguana_soc` (compiled with `NO_HYPERBUS`), exposing only the
// ports this lane drives from C++: clock/reset/RTC and JTAG (for the
// DMI-based ELF preload and end-of-computation poll) plus UART (for
// captured program output). Everything else `iguana_soc` exposes (I2C, SPI,
// GPIO, VGA, USB, serial link, hyperbus) is tied to its idle value here -
// this DUT does not exercise those interfaces.
//
// See openspec/changes/verilator-sim-flow/design.md (D1) for why this wraps
// `iguana_soc` directly instead of duplicating `cheshire_soc`'s port list,
// and why `NO_HYPERBUS` is used instead of dragging in the hyperbus PHY for
// a test that never touches it.

module newt_verilator_top
  import iguana_pkg::*;
  import cheshire_pkg::*;
(
  input  logic clk_i,
  input  logic rst_ni,
  input  logic rtc_i,

  input  logic jtag_tck_i,
  input  logic jtag_trst_ni,
  input  logic jtag_tms_i,
  input  logic jtag_tdi_i,
  output logic jtag_tdo_o,

  output logic uart_tx_o
);

  // This lane only supports SPM boot (BOOTMODE 0); see the "Unsupported
  // configuration is rejected clearly" spec scenario - other modes are
  // rejected by the C++ driver before this harness is ever exercised.
  localparam logic [1:0] BootModeSpm = 2'b00;

  logic jtag_tdo_oe;

  // I2C - unused, idle bus
  logic i2c_sda_o, i2c_sda_en_o;
  logic i2c_scl_o, i2c_scl_en_o;

  // SPI host - unused
  logic                 spih_sck_o, spih_sck_en_o;
  logic [SpihNumCs-1:0] spih_csb_o, spih_csb_en_o;
  logic [           3:0] spih_sd_o, spih_sd_en_o;

  // GPIO - unused
  logic [GpioNumWired-1:0] gpio_o, gpio_en_o;

  // Serial link - unused
  logic [SlinkNumChan-1:0]                    slink_rcv_clk_o;
  logic [SlinkNumChan-1:0][SlinkNumLanes-1:0] slink_o;

  // VGA - unused
  logic vga_hsync_o, vga_vsync_o;
  logic [  VgaOutRedWidth-1:0] vga_red_o;
  logic [VgaOutGreenWidth-1:0] vga_green_o;
  logic [ VgaOutBlueWidth-1:0] vga_blue_o;

  // Hyperbus - tied off internally by iguana_soc (NO_HYPERBUS); still
  // top-level ports that must be terminated here.
  logic [HypNumPhys-1:0][HypNumChips-1:0] hyper_cs_no;
  logic [HypNumPhys-1:0]                  hyper_ck_o, hyper_ck_no;
  logic [HypNumPhys-1:0]                  hyper_rwds_o, hyper_rwds_oe_o;
  logic [HypNumPhys-1:0][             7:0] hyper_dq_o;
  logic [HypNumPhys-1:0]                  hyper_dq_oe_o;
  logic [HypNumPhys-1:0]                  hyper_reset_no;

  iguana_soc i_dut (
    .clk_i,
    .rst_ni,
    .test_mode_i     ( 1'b0        ),
    .boot_mode_i     ( BootModeSpm ),
    .rtc_i,

    .jtag_tck_i,
    .jtag_trst_ni,
    .jtag_tms_i,
    .jtag_tdi_i,
    .jtag_tdo_o,
    .jtag_tdo_oe_o   ( jtag_tdo_oe ),

    .uart_tx_o,
    .uart_rx_i       ( 1'b1 ), // idle (mark) state; this lane does not drive UART RX

    .i2c_sda_o,
    .i2c_sda_i       ( 1'b1 ),
    .i2c_sda_en_o,
    .i2c_scl_o,
    .i2c_scl_i       ( 1'b1 ),
    .i2c_scl_en_o,

    .spih_sck_o,
    .spih_sck_en_o,
    .spih_csb_o,
    .spih_csb_en_o,
    .spih_sd_o,
    .spih_sd_en_o,
    .spih_sd_i       ( 4'hF ),

    .usb_clk_i       ( clk_i ),
    .gpio_i          ( '0    ),
    .gpio_o,
    .gpio_en_o,

    .slink_rcv_clk_i ( '0 ),
    .slink_rcv_clk_o,
    .slink_i         ( '0 ),
    .slink_o,

    .vga_hsync_o,
    .vga_vsync_o,
    .vga_red_o,
    .vga_green_o,
    .vga_blue_o,

    .hyper_cs_no,
    .hyper_ck_o,
    .hyper_ck_no,
    .hyper_rwds_o,
    .hyper_rwds_i    ( '0 ),
    .hyper_rwds_oe_o,
    .hyper_dq_i      ( '0 ),
    .hyper_dq_o,
    .hyper_dq_oe_o,
    .hyper_reset_no
  );

endmodule
