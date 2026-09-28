// Copyright 2026 Kyiv School of Economics.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Xcelium lane fixture: `iguana_soc` (compiled with NO_HYPERBUS, the same DUT
// as the Verilator lane) driven by Cheshire's own VIP. Unlike `fixture_iguana`
// there are no pads and no hyperram model: the LLC's external port is tied
// off inside `iguana_soc`, so only SPM-linked programs can run.
module fixture_newt_xrun;

  import cheshire_pkg::*;
  import iguana_pkg::*;

  ///////////
  //  DUT  //
  ///////////

  logic       clk;
  logic       rst_n;
  logic       test_mode;
  logic [1:0] boot_mode;
  logic       rtc;

  logic jtag_tck;
  logic jtag_trst_n;
  logic jtag_tms;
  logic jtag_tdi;
  logic jtag_tdo;

  logic uart_tx;
  logic uart_rx;

  logic i2c_sda_o;
  logic i2c_sda_i;
  logic i2c_sda_en;
  logic i2c_scl_o;
  logic i2c_scl_i;
  logic i2c_scl_en;

  logic                 spih_sck_o;
  logic                 spih_sck_en;
  logic [SpihNumCs-1:0] spih_csb_o;
  logic [SpihNumCs-1:0] spih_csb_en;
  logic [ 3:0]          spih_sd_o;
  logic [ 3:0]          spih_sd_i;
  logic [ 3:0]          spih_sd_en;

  logic [SlinkNumChan-1:0]                    slink_rcv_clk_i;
  logic [SlinkNumChan-1:0]                    slink_rcv_clk_o;
  logic [SlinkNumChan-1:0][SlinkNumLanes-1:0] slink_i;
  logic [SlinkNumChan-1:0][SlinkNumLanes-1:0] slink_o;

  iguana_soc i_dut (
    .clk_i            ( clk       ),
    .rst_ni           ( rst_n     ),
    .test_mode_i      ( test_mode ),
    .boot_mode_i      ( boot_mode ),
    .rtc_i            ( rtc       ),
    .jtag_tck_i       ( jtag_tck    ),
    .jtag_trst_ni     ( jtag_trst_n ),
    .jtag_tms_i       ( jtag_tms    ),
    .jtag_tdi_i       ( jtag_tdi    ),
    .jtag_tdo_o       ( jtag_tdo    ),
    .jtag_tdo_oe_o    ( ),
    .uart_tx_o        ( uart_tx ),
    .uart_rx_i        ( uart_rx ),
    .i2c_sda_o        ( i2c_sda_o  ),
    .i2c_sda_i        ( i2c_sda_i  ),
    .i2c_sda_en_o     ( i2c_sda_en ),
    .i2c_scl_o        ( i2c_scl_o  ),
    .i2c_scl_i        ( i2c_scl_i  ),
    .i2c_scl_en_o     ( i2c_scl_en ),
    .spih_sck_o       ( spih_sck_o  ),
    .spih_sck_en_o    ( spih_sck_en ),
    .spih_csb_o       ( spih_csb_o  ),
    .spih_csb_en_o    ( spih_csb_en ),
    .spih_sd_o        ( spih_sd_o   ),
    .spih_sd_en_o     ( spih_sd_en  ),
    .spih_sd_i        ( spih_sd_i   ),
    .usb_clk_i        ( 1'b0 ),
    .gpio_i           ( '0 ),
    .gpio_o           ( ),
    .gpio_en_o        ( ),
    .slink_rcv_clk_i  ( slink_rcv_clk_i ),
    .slink_rcv_clk_o  ( slink_rcv_clk_o ),
    .slink_i          ( slink_i ),
    .slink_o          ( slink_o ),
    .vga_hsync_o      ( ),
    .vga_vsync_o      ( ),
    .vga_red_o        ( ),
    .vga_green_o      ( ),
    .vga_blue_o       ( ),
    .hyper_cs_no      ( ),
    .hyper_ck_o       ( ),
    .hyper_ck_no      ( ),
    .hyper_rwds_o     ( ),
    .hyper_rwds_i     ( '0 ),
    .hyper_rwds_oe_o  ( ),
    .hyper_dq_i       ( '0 ),
    .hyper_dq_o       ( ),
    .hyper_dq_oe_o    ( ),
    .hyper_reset_no   ( )
  );

  ////////////////////////
  //  Tristate Adapter  //
  ////////////////////////

  wire i2c_sda;
  wire i2c_scl;

  wire                 spih_sck;
  wire [SpihNumCs-1:0] spih_csb;
  wire [ 3:0]          spih_sd;

  vip_cheshire_soc_tristate vip_tristate (.*);

  ///////////
  //  VIP  //
  ///////////

  // The VIP models memory behind the LLC's external port, but iguana_soc does
  // not expose that port under NO_HYPERBUS: keep the VIP side idle.
  axi_llc_req_t axi_llc_mst_req;
  axi_llc_rsp_t axi_llc_mst_rsp;

  assign axi_llc_mst_req = '0;

  axi_mst_req_t axi_slink_mst_req;
  axi_mst_rsp_t axi_slink_mst_rsp;

  assign axi_slink_mst_req = '0;

  // Same timing as fixture_iguana.
  vip_cheshire_soc #(
    .DutCfg             ( CheshireCfg   ),
    .axi_ext_llc_req_t  ( axi_llc_req_t ),
    .axi_ext_llc_rsp_t  ( axi_llc_rsp_t ),
    .axi_ext_mst_req_t  ( axi_mst_req_t ),
    .axi_ext_mst_rsp_t  ( axi_mst_rsp_t ),
    .ClkPeriodSys       ( 10ns ),
    .ClkPeriodJtag      ( 40ns ),
    .RstCycles          ( 20 )
  ) vip (.*);

endmodule
