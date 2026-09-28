// Copyright 2026 Kyiv School of Economics.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Xcelium lane testbench. Control flow follows tb_iguana (minus the hyperram
// power-up wait). Every run ends by printing exactly one line
//   [NEWT-XRUN] RESULT EXIT=<n> | TIMEOUT | UNSUPPORTED <what>
// which run.sh turns into the per-test verdict.
//
// Plusargs: +BINARY=<elf> +BOOTMODE=<n> +PRELMODE=<n> +IMAGE=<memh>
//           +TIMEOUT_NS=<simulated ns, default 10 ms>
`timescale 1ns/1ps
module tb_newt_xrun;

  localparam longint unsigned DefaultTimeoutNs = 64'd10_000_000;

  fixture_newt_xrun fix();

  string                preload_elf;
  string                boot_hex;
  int unsigned          boot_mode;
  int unsigned          preload_mode;
  cheshire_pkg::word_bt exit_code;
  bit                   reported;

  task automatic report(input string what);
    if (!reported) begin
      reported = 1'b1;
      $display("[NEWT-XRUN] RESULT %s", what);
    end
    $finish;
  endtask

  initial begin
    int fd;

    if (!$value$plusargs("BOOTMODE=%d", boot_mode))    boot_mode    = 0;
    if (!$value$plusargs("PRELMODE=%d", preload_mode)) preload_mode = 0;
    if (!$value$plusargs("BINARY=%s",   preload_elf))  preload_elf  = "";
    if (!$value$plusargs("IMAGE=%s",    boot_hex))     boot_hex     = "";

    // Reject what this lane cannot run before spending simulated time on it.
    if (boot_mode == 1 || boot_mode > 3)
      report($sformatf("UNSUPPORTED BOOTMODE=%0d", boot_mode));
    if (boot_mode == 0) begin
      if (preload_mode > 2)
        report($sformatf("UNSUPPORTED PRELMODE=%0d", preload_mode));
      fd = $fopen(preload_elf, "r");
      if (fd == 0) report($sformatf("UNSUPPORTED BINARY='%s' (not readable)", preload_elf));
      $fclose(fd);
    end

    fix.vip.set_boot_mode(boot_mode[1:0]);
    fix.vip.i2c_eeprom_preload(boot_hex);
    fix.vip.spih_norflash_preload(boot_hex);
    fix.vip.wait_for_reset();

    if (boot_mode == 0) begin
      case (preload_mode)
        0: begin // JTAG
          fix.vip.jtag_init();
          fix.vip.jtag_elf_run(preload_elf);
          fix.vip.jtag_wait_for_eoc(exit_code);
        end
        1: begin // Serial Link
          fix.vip.slink_elf_run(preload_elf);
          fix.vip.slink_wait_for_eoc(exit_code);
        end
        default: begin // 2: UART
          fix.vip.uart_debug_elf_run_and_wait(preload_elf, exit_code);
        end
      endcase
    end else begin
      // Autonomous boot (SPI NOR flash / I2C EEPROM): only poll the return code
      fix.vip.jtag_init();
      fix.vip.jtag_wait_for_eoc(exit_code);
    end

    report($sformatf("EXIT=%0d", exit_code));
  end

  // Simulated-time watchdog
  initial begin
    longint unsigned timeout_ns;
    if (!$value$plusargs("TIMEOUT_NS=%d", timeout_ns)) timeout_ns = DefaultTimeoutNs;
    #(timeout_ns * 1ns);
    report("TIMEOUT");
  end

  // Progress heartbeat, so a slow run is distinguishable from a hung one
  initial begin
    $timeformat(-3, 3, " ms", 10);
    forever begin
      #1ms;
      $display("[NEWT-XRUN] time %t", $realtime);
    end
  end

endmodule
