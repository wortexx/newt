// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// C++ driver for the Verilator simulation lane. Owns everything the SV
// harness (newt_verilator_top.sv) does not: clock/reset/RTC generation, a
// from-scratch JTAG-DTM + RISC-V Debug Module driver bit-banged against the
// harness's JTAG pins (used to preload an ELF over system-bus access and
// resume the hart at its entry point), a UART TX bit-sampler that decodes
// and prints program output, and end-of-computation detection via the same
// DMI/SBA path, polling Cheshire's scratch register.
//
// The DM/JTAG register map (dm_csr_e addresses, dmcontrol_t/dmstatus_t/
// abstractcs_t/sbcs_t bit layouts, the 41-bit {addr,data,op} DMI shift
// register) and the address-map constants (AmRegs/AmLlc, the LLC SPM config
// and Cheshire scratch-2 offsets) are ported from riscv-dbg's dm_pkg.sv /
// dmi_jtag.sv and cheshire_pkg.sv. The operation sequence (wait for the boot
// ROM to configure the LLC as SPM, halt, preload over SBA, set dpc via an
// abstract register-access command, resume, poll for end-of-computation) is
// ported from Cheshire's target/sim/src/vip_cheshire_soc.sv JTAG tasks -
// see openspec/changes/verilator-sim-flow/design.md (D3-D5) for the design
// rationale and openspec/changes/verilator-sim-flow/tasks.md for exact
// constant provenance.
//
// The ELF64 program-header parser is adapted from Cheshire's
// target/sim/src/elfloader.cpp (Copyright 2022 ETH Zurich and University of
// Bologna, itself modified from the RISC-V Frontend Server), stripped of its
// DPI-C interface since this driver calls it directly from C++.

#include "Vnewt_verilator_top.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

// ==========================================================================
// ELF64 loader (PT_LOAD segments only; this project always builds RV64 ELFs)
// ==========================================================================

namespace elf {

struct Ehdr64 {
  uint8_t e_ident[16];
  uint16_t e_type;
  uint16_t e_machine;
  uint32_t e_version;
  uint64_t e_entry;
  uint64_t e_phoff;
  uint64_t e_shoff;
  uint32_t e_flags;
  uint16_t e_ehsize;
  uint16_t e_phentsize;
  uint16_t e_phnum;
  uint16_t e_shentsize;
  uint16_t e_shnum;
  uint16_t e_shstrndx;
};

struct Phdr64 {
  uint32_t p_type;
  uint32_t p_flags;
  uint64_t p_offset;
  uint64_t p_vaddr;
  uint64_t p_paddr;
  uint64_t p_filesz;
  uint64_t p_memsz;
  uint64_t p_align;
};

constexpr uint32_t kPtLoad = 1;

struct Segment {
  uint64_t addr = 0;
  // Zero-extended to p_memsz at load time (covers .bss) so the SBA preload
  // loop never has to special-case a partial tail write against target
  // memory whose reset value is otherwise unspecified (X) in RTL sim -
  // stricter than elfloader.cpp's original "leave it unwritten" behavior.
  std::vector<uint8_t> data;
};

struct Image {
  uint64_t entry = 0;
  std::vector<Segment> segments;
};

static bool load(const std::string &path, Image &img) {
  int fd = open(path.c_str(), O_RDONLY);
  if (fd < 0) {
    fprintf(stderr, "[ELF] ERROR: cannot open %s\n", path.c_str());
    return false;
  }
  struct stat st;
  if (fstat(fd, &st) < 0) {
    fprintf(stderr, "[ELF] ERROR: cannot stat %s\n", path.c_str());
    close(fd);
    return false;
  }
  size_t size = static_cast<size_t>(st.st_size);
  if (size < sizeof(Ehdr64)) {
    fprintf(stderr, "[ELF] ERROR: %s is too small to contain a valid ELF header\n", path.c_str());
    close(fd);
    return false;
  }
  void *map = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
  close(fd);
  if (map == MAP_FAILED) {
    fprintf(stderr, "[ELF] ERROR: mmap failed for %s\n", path.c_str());
    return false;
  }
  const uint8_t *buf = static_cast<const uint8_t *>(map);
  const Ehdr64 *eh = reinterpret_cast<const Ehdr64 *>(buf);
  bool is_elf64 = eh->e_ident[0] == 0x7f && eh->e_ident[1] == 'E' && eh->e_ident[2] == 'L' &&
                  eh->e_ident[3] == 'F' && eh->e_ident[4] == 2;
  if (!is_elf64) {
    fprintf(stderr, "[ELF] ERROR: %s is not a valid ELF64 file\n", path.c_str());
    munmap(map, size);
    return false;
  }
  if (size < eh->e_phoff + uint64_t(eh->e_phnum) * sizeof(Phdr64)) {
    fprintf(stderr, "[ELF] ERROR: %s program headers exceed the file size\n", path.c_str());
    munmap(map, size);
    return false;
  }
  img.entry = eh->e_entry;
  const Phdr64 *ph = reinterpret_cast<const Phdr64 *>(buf + eh->e_phoff);
  for (unsigned i = 0; i < eh->e_phnum; ++i) {
    if (ph[i].p_type != kPtLoad || ph[i].p_memsz == 0) continue;
    Segment seg;
    seg.addr = ph[i].p_paddr;
    seg.data.assign(ph[i].p_memsz, 0);
    if (ph[i].p_filesz) {
      if (size < ph[i].p_offset + ph[i].p_filesz) {
        fprintf(stderr, "[ELF] ERROR: a PT_LOAD segment exceeds the file size\n");
        munmap(map, size);
        return false;
      }
      memcpy(seg.data.data(), buf + ph[i].p_offset, ph[i].p_filesz);
    }
    img.segments.push_back(std::move(seg));
  }
  munmap(map, size);
  return true;
}

}  // namespace elf

// ==========================================================================
// RISC-V Debug Module / JTAG-DTM constants
// Ported from riscv-dbg's src/dm_pkg.sv (register map, bit layouts) and
// src/dmi_jtag.sv (DMI shift-register width/layout, fixed abits=7).
// ==========================================================================

namespace dm {

// JTAG IR (5 bits) - dmi_jtag_tap.sv ir_reg_e
constexpr uint8_t kIrLength = 5;
constexpr uint8_t kIrIdcode = 0x01;
constexpr uint8_t kIrDtmcsr = 0x10;
constexpr uint8_t kIrDmiAccess = 0x11;

// dtmcs_t.dmireset (bit 16) - the *only* way to clear the DTM's sticky
// DMI error/busy latch (dm_pkg.sv error_q survives past the transaction
// that set it and blocks all further DMI Idle-state acceptance until this
// is issued). Ported from croc's riscv_dbg_simple::reset_dmi() - see
// design.md's DM protocol blocker addendum for how this was found.
constexpr uint32_t kDtmcsDmireset = 1u << 16;

// DMI DR: {addr[6:0], data[31:0], op[1:0]} = 41 bits (dmi_jtag.sv: abits=7)
constexpr int kDmiBits = 41;
constexpr uint8_t kDmiOpNop = 0;
constexpr uint8_t kDmiOpRead = 1;
constexpr uint8_t kDmiOpWrite = 2;
constexpr uint8_t kDmiRespSuccess = 0;
constexpr uint8_t kDmiRespErr = 2;
constexpr uint8_t kDmiRespBusy = 3;

// dm_csr_e (dm_pkg.sv)
constexpr uint8_t kData0 = 0x04;
constexpr uint8_t kData1 = 0x05;
constexpr uint8_t kDmControl = 0x10;
constexpr uint8_t kDmStatus = 0x11;
constexpr uint8_t kAbstractCs = 0x16;
constexpr uint8_t kCommand = 0x17;
constexpr uint8_t kSbcs = 0x38;
constexpr uint8_t kSbAddress0 = 0x39;
constexpr uint8_t kSbAddress1 = 0x3A;
constexpr uint8_t kSbData0 = 0x3C;
constexpr uint8_t kSbData1 = 0x3D;

// dmcontrol_t (bit 31 = haltreq downto bit 0 = dmactive)
constexpr uint32_t kDmcontrolHaltreq = 1u << 31;
constexpr uint32_t kDmcontrolResumereq = 1u << 30;
constexpr uint32_t kDmcontrolDmactive = 1u << 0;

// dmstatus_t
constexpr uint32_t kDmstatusAllhalted = 1u << 9;

// abstractcs_t
constexpr uint32_t kAbstractcsBusy = 1u << 12;
constexpr uint32_t kAbstractcsCmderrMask = 0x7u << 8;

// sbcs_t (bit 31 = sbversion[2] downto bit 0 = sbaccess8)
constexpr uint32_t kSbcsSbbusyerror = 1u << 22;
constexpr uint32_t kSbcsSbbusy = 1u << 21;
constexpr uint32_t kSbcsSbreadonaddr = 1u << 20;
constexpr uint32_t kSbcsSbautoincrement = 1u << 16;
constexpr uint32_t kSbcsSbreadondata = 1u << 15;
constexpr uint32_t kSbcsSberrorMask = 0x7u << 12;
static uint32_t sbcs_access(uint32_t access3) { return (access3 & 0x7u) << 17; }

// Abstract command 0x0033_07b1: AccessRegister, transfer+write, aarsize=64b
// (011), regno=0x7b1 (CSR `dpc`, the Debug Program Counter) - writes the
// resume PC from dm::Data1/Data0. Ported verbatim from
// vip_cheshire_soc.sv's jtag_elf_run task; see the RISC-V debug spec's
// Command register (0x17) AccessRegister encoding for the field layout.
constexpr uint32_t kCommandWriteDpc = 0x003307B1u;

// cheshire_pkg.sv address map (this project's CheshireCfg: LlcNotBypass=1,
// inherited unmodified from cheshire_pkg's default generator - see
// hw/iguana_pkg.sv). axi_llc_reg_pkg.sv / cheshire_reg_pkg.sv offsets.
constexpr uint64_t kAmRegs = 0x03000000ULL;
constexpr uint64_t kAmLlc = 0x03001000ULL;
constexpr uint64_t kAxiLlcCfgSpmLowOffset = 0x0ULL;
constexpr uint64_t kCheshireScratch2Offset = 0x8ULL;

}  // namespace dm

// ==========================================================================
// 16x-oversampling UART RX (8N1) - decodes newt_verilator_top's uart_tx_o
// ==========================================================================

class UartRx {
 public:
  explicit UartRx(int oversample = 16) : oversample_(oversample) {}

  // Call once per uart_sample_ps tick with the current uart_tx_o level.
  void Sample(bool line) {
    switch (state_) {
      case State::kIdle:
        if (!line) {
          state_ = State::kStart;
          sub_ = 0;
        }
        break;
      case State::kStart:
        // Confirm the falling edge at the middle of the start bit, not the
        // first sample after it, to reject glitches.
        if (++sub_ == oversample_ / 2) {
          sub_ = 0;
          if (!line) {
            state_ = State::kData;
            bit_idx_ = 0;
            byte_ = 0;
          } else {
            state_ = State::kIdle;
          }
        }
        break;
      case State::kData:
        if (++sub_ == oversample_) {
          sub_ = 0;
          if (line) byte_ |= uint8_t(1u << bit_idx_);
          if (++bit_idx_ == 8) state_ = State::kStop;
        }
        break;
      case State::kStop:
        if (++sub_ == oversample_) {
          sub_ = 0;
          state_ = State::kIdle;
          putchar(byte_);
          fflush(stdout);
        }
        break;
    }
  }

 private:
  enum class State { kIdle, kStart, kData, kStop };
  State state_ = State::kIdle;
  int oversample_;
  int sub_ = 0;
  int bit_idx_ = 0;
  uint8_t byte_ = 0;
};

// ==========================================================================
// Testbench: clock/reset generation, JTAG-DTM bit-banging, DM/SBA driver
// ==========================================================================

class Tb {
 public:
  Tb(VerilatedContext *contextp, Vnewt_verilator_top *top, uint32_t uart_baud)
      : contextp_(contextp), top_(top) {
    // Timing matches this project's own Questa fixture
    // (target/sim/src/fixture_iguana.sv: ClkPeriodSys=10ns,
    // ClkPeriodJtag=40ns, RstCycles=20) so the boot code's runtime UART
    // baud calibration (clint_get_core_freq() against rtc_i, see
    // sw/tests/helloworld.c) lands at the same effective baud regardless of
    // which simulator drives it.
    sys_half_ps_ = 5'000;
    rtc_half_ps_ = 15'259'000;  // 30518ns / 2
    jtag_half_ps_ = 20'000;
    uint64_t uart_bit_ps = uint64_t(1e12 / double(uart_baud));
    uart_sample_ps_ = std::max<uint64_t>(1, uart_bit_ps / 16);

    top_->clk_i = 0;
    top_->rtc_i = 0;
    next_clk_ps_ = sys_half_ps_;
    next_rtc_ps_ = rtc_half_ps_;
    next_uart_ps_ = uart_sample_ps_;
  }

  uint64_t sys_cycles() const { return sys_cycles_; }

  // ---- Clock/reset -------------------------------------------------------

  void Reset(int rst_sys_cycles) {
    top_->rst_ni = 0;
    top_->jtag_trst_ni = 0;
    top_->jtag_tms_i = 1;
    top_->jtag_tdi_i = 0;
    top_->jtag_tck_i = 0;
    top_->eval();
    AdvanceTime(uint64_t(rst_sys_cycles) * 2 * sys_half_ps_);
    top_->rst_ni = 1;
    top_->jtag_trst_ni = 1;
    top_->eval();
    AdvanceTime(4 * 2 * sys_half_ps_);
    TapReset();
  }

  // ---- JTAG TAP primitives -------------------------------------------

  // Drives one TCK pulse with the given TMS/TDI and returns the sampled
  // TDO. Background clocks (sys, RTC, UART sampler) keep advancing
  // regardless of what this call does, via AdvanceTime().
  uint8_t JtagPulse(bool tms, bool tdi) {
    top_->jtag_tms_i = tms;
    top_->jtag_tdi_i = tdi;
    top_->jtag_tck_i = 0;
    top_->eval();
    AdvanceTime(jtag_half_ps_);
    top_->jtag_tck_i = 1;
    top_->eval();
    AdvanceTime(jtag_half_ps_);
    return top_->jtag_tdo_o & 1;
  }

  void JtagIdleCycles(int n) {
    for (int i = 0; i < n; ++i) JtagPulse(false, false);
  }

  // Guarantees Test-Logic-Reset regardless of current TAP state, then
  // returns to Run-Test/Idle.
  void TapReset() {
    for (int i = 0; i < 6; ++i) JtagPulse(true, false);
    JtagPulse(false, false);
  }

  void GotoShiftIr() {
    JtagPulse(true, false);   // RTI -> Select-DR-Scan
    JtagPulse(true, false);   // -> Select-IR-Scan
    JtagPulse(false, false);  // -> Capture-IR
    JtagPulse(false, false);  // -> Shift-IR
  }

  void GotoShiftDr() {
    JtagPulse(true, false);   // RTI -> Select-DR-Scan
    JtagPulse(false, false);  // -> Capture-DR
    JtagPulse(false, false);  // -> Shift-DR
  }

  // Must already be positioned in Shift-IR/Shift-DR. Shifts `nbits` of
  // `value_in` MSB-first (matching this design's right-shift, insert-at-MSB
  // shift register - see dmi_jtag.sv/dmi_jtag_tap.sv), captures the
  // previous register content LSB-first, and exits through
  // Exit1 -> Update -> Run-Test/Idle.
  uint64_t ShiftValue(uint64_t value_in, int nbits) {
    uint64_t captured = 0;
    for (int k = 0; k < nbits; ++k) {
      int send_idx = nbits - 1 - k;
      bool tdi = (value_in >> send_idx) & 1;
      bool last = (k == nbits - 1);
      uint8_t tdo = JtagPulse(last, tdi);
      captured |= (uint64_t(tdo) << k);
    }
    JtagPulse(true, false);   // Exit1 -> Update
    JtagPulse(false, false);  // Update -> Run-Test/Idle
    return captured;
  }

  // Only shifts IR when it actually needs to change - matches
  // riscv_dbg_simple::jtag_driver_simple::set_ir()'s early-return, which
  // is what makes it cheap to call this before every DMI/DTMCS access
  // instead of assuming IR stays latched (it doesn't, once DTMCS access
  // is introduced below - see ResetDmi()).
  void SelectIr(uint8_t ir_value) {
    if (ir_selected_ == ir_value) return;
    GotoShiftIr();
    ShiftValue(ir_value, dm::kIrLength);
    ir_selected_ = ir_value;
  }
  uint8_t ir_selected_ = 0xFF;  // no IR selected yet

  // Writes the 32-bit DTMCS register directly (IR=DTMCSR, not DMIACCESS -
  // this is a different scan chain from the DMI one).
  void WriteDtmcs(uint32_t value) {
    SelectIr(dm::kIrDtmcsr);
    GotoShiftDr();
    ShiftValue(value, 32);
  }

  // Clears the DTM's sticky DMI error/busy latch (dm_pkg.sv's error_q).
  // Required before retrying a DMI transaction that came back BUSY -
  // without this, the DTM permanently refuses new DMI requests (see the
  // `kDtmcsDmireset` comment and design.md's DM protocol blocker
  // addendum). Ported from croc's riscv_dbg_simple::reset_dmi().
  void ResetDmi() { WriteDtmcs(dm::kDtmcsDmireset); }

  // ---- DMI ----------------------------------------------------------

  struct DmiResult {
    uint32_t data;
    uint8_t resp;
  };

  DmiResult DmiShift(uint8_t addr7, uint32_t data32, uint8_t op2) {
    SelectIr(dm::kIrDmiAccess);  // no-op if already selected (see SelectIr)
    GotoShiftDr();
    uint64_t value_in = (uint64_t(addr7 & 0x7F) << 34) | (uint64_t(data32) << 2) | (op2 & 0x3);
    uint64_t captured = ShiftValue(value_in, dm::kDmiBits);
    DmiResult r;
    r.data = uint32_t((captured >> 2) & 0xFFFFFFFFu);
    r.resp = uint8_t(captured & 0x3);
    return r;
  }

  void DmiWrite(uint8_t addr, uint32_t data) {
    for (int attempt = 0; attempt < 64; ++attempt) {
      DmiResult r = DmiShift(addr, data, dm::kDmiOpWrite);
      if (r.resp == dm::kDmiRespBusy) {
        ResetDmi();  // clear the sticky busy latch before retrying
        JtagIdleCycles(16);
        continue;
      }
      if (r.resp != dm::kDmiRespSuccess) {
        fprintf(stderr, "[JTAG] WARNING: DMI write to 0x%02x got resp=%u\n", addr, r.resp);
      }
      return;
    }
    fprintf(stderr, "[JTAG] ERROR: DMI write to 0x%02x stayed busy\n", addr);
    exit(1);
  }

  uint32_t DmiRead(uint8_t addr) {
    DmiShift(addr, 0, dm::kDmiOpRead);  // issue; this shift's own result is stale
    // The DM needs time after the issuing shift to actually latch the
    // requested register's value before the retrieve shift below can see
    // it - without this, the retrieve can see resp=SUCCESS with stale/
    // not-yet-settled data instead of a resp=BUSY it would be safe to
    // retry on. Idle cycles here, not just on the busy-retry path.
    JtagIdleCycles(16);
    for (int attempt = 0; attempt < 64; ++attempt) {
      DmiResult r = DmiShift(addr, 0, dm::kDmiOpNop);  // retrieve (same addr, matches croc)
      if (r.resp == dm::kDmiRespBusy) {
        ResetDmi();  // clear the sticky busy latch before retrying
        JtagIdleCycles(16);
        continue;
      }
      if (r.resp != dm::kDmiRespSuccess) {
        fprintf(stderr, "[JTAG] WARNING: DMI read from 0x%02x got resp=%u\n", addr, r.resp);
      }
      return r.data;
    }
    fprintf(stderr, "[JTAG] ERROR: DMI read from 0x%02x stayed busy\n", addr);
    exit(1);
  }

  // ---- System Bus Access (SBA) ---------------------------------------

  void SbaWaitIdle() {
    for (int i = 0; i < 256; ++i) {
      uint32_t sbcs = DmiRead(dm::kSbcs);
      if (sbcs & dm::kSbcsSbbusyerror) {
        fprintf(stderr, "[JTAG] ERROR: SBA busy-error flag set\n");
        exit(1);
      }
      if (sbcs & dm::kSbcsSberrorMask) {
        fprintf(stderr, "[JTAG] ERROR: SBA bus error (sberror=%u)\n", (sbcs >> 12) & 0x7);
        exit(1);
      }
      if (!(sbcs & dm::kSbcsSbbusy)) return;
      JtagIdleCycles(8);
    }
    fprintf(stderr, "[JTAG] ERROR: SBA stayed busy too long\n");
    exit(1);
  }

  // Polls a 32-bit-aligned word until its bit 0 is set (the vip's "ready"
  // convention for both the LLC SPM-config gate and the EOC scratch reg),
  // returning the full word so the caller can extract payload bits.
  uint32_t SbaPollBit0(uint64_t addr, int idle_cycles) {
    uint32_t poll_sbcs = dm::kSbcsSbreadonaddr | dm::sbcs_access(2);  // 32-bit
    DmiWrite(dm::kSbcs, poll_sbcs);
    SbaWaitIdle();
    DmiWrite(dm::kSbAddress1, uint32_t(addr >> 32));
    uint32_t data;
    do {
      DmiWrite(dm::kSbAddress0, uint32_t(addr & 0xFFFFFFFFu));  // triggers a read (sbreadonaddr)
      JtagIdleCycles(idle_cycles);
      data = DmiRead(dm::kSbData0);
    } while (!(data & 1));
    return data;
  }

  // 64-bit autoincrementing write of one ELF segment, 8 bytes per DMI
  // round-trip (SBData1=high word, SBData0=low word - writing SBData0
  // triggers the bus write per the debug spec's SBA convention).
  void SbaPreloadSegment(uint64_t addr, const std::vector<uint8_t> &bytes) {
    uint32_t sbcs = dm::kSbcsSbautoincrement | dm::kSbcsSbreadondata | dm::sbcs_access(3);  // 64-bit
    DmiWrite(dm::kSbcs, sbcs);
    SbaWaitIdle();
    DmiWrite(dm::kSbAddress1, uint32_t(addr >> 32));
    DmiWrite(dm::kSbAddress0, uint32_t(addr & 0xFFFFFFFFu));
    for (size_t i = 0; i < bytes.size(); i += 8) {
      uint32_t lo = 0, hi = 0;
      for (int b = 0; b < 4 && i + b < bytes.size(); ++b) lo |= uint32_t(bytes[i + b]) << (8 * b);
      for (int b = 0; b < 4 && i + 4 + b < bytes.size(); ++b)
        hi |= uint32_t(bytes[i + 4 + b]) << (8 * b);
      DmiWrite(dm::kSbData1, hi);
      DmiWrite(dm::kSbData0, lo);
    }
    SbaWaitIdle();
  }

  // ---- Debug module bring-up / run sequence --------------------------

  void JtagInit() {
    SelectIr(dm::kIrDmiAccess);  // stays latched for every subsequent DMI shift
    DmiWrite(dm::kDmControl, dm::kDmcontrolDmactive);
    for (int i = 0; i < 64; ++i) {
      if (DmiRead(dm::kDmControl) & dm::kDmcontrolDmactive) break;
      JtagIdleCycles(8);
    }
    uint32_t init_sbcs = dm::kSbcsSbautoincrement | dm::kSbcsSbreadondata | dm::sbcs_access(3);
    DmiWrite(dm::kSbcs, init_sbcs);
    SbaWaitIdle();
    printf("[JTAG] Initialization success\n");
  }

  void HaltAndLoad(const elf::Image &img) {
    printf("[JTAG] Waiting for the boot ROM to configure the LLC as SPM\n");
    SbaPollBit0(dm::kAmLlc + dm::kAxiLlcCfgSpmLowOffset, 20);
    DmiWrite(dm::kDmControl, dm::kDmcontrolHaltreq | dm::kDmcontrolDmactive);
    bool halted = false;
    for (int i = 0; i < 256; ++i) {
      if (DmiRead(dm::kDmStatus) & dm::kDmstatusAllhalted) {
        halted = true;
        break;
      }
      JtagIdleCycles(8);
    }
    if (!halted) {
      fprintf(stderr, "[JTAG] ERROR: hart 0 did not report allhalted after haltreq\n");
      exit(1);
    }
    printf("[JTAG] Halted hart 0\n");
    for (auto &seg : img.segments) {
      printf("[JTAG] Preloading segment at 0x%llx (%zu bytes)\n",
             static_cast<unsigned long long>(seg.addr), seg.data.size());
      SbaPreloadSegment(seg.addr, seg.data);
    }
  }

  void SetDpcAndResume(uint64_t entry) {
    DmiWrite(dm::kData1, uint32_t(entry >> 32));
    DmiWrite(dm::kData0, uint32_t(entry & 0xFFFFFFFFu));
    DmiWrite(dm::kCommand, dm::kCommandWriteDpc);
    bool done = false;
    for (int i = 0; i < 64; ++i) {
      uint32_t acs = DmiRead(dm::kAbstractCs);
      if (!(acs & dm::kAbstractcsBusy)) {
        if (acs & dm::kAbstractcsCmderrMask) {
          fprintf(stderr, "[JTAG] ERROR: abstract command error setting dpc (cmderr=%u)\n",
                  (acs >> 8) & 0x7);
          exit(1);
        }
        done = true;
        break;
      }
      JtagIdleCycles(8);
    }
    if (!done) {
      fprintf(stderr, "[JTAG] ERROR: abstract command to set dpc stayed busy\n");
      exit(1);
    }
    DmiWrite(dm::kDmControl, dm::kDmcontrolResumereq | dm::kDmcontrolDmactive);
    printf("[JTAG] Resumed hart 0 from 0x%llx\n", static_cast<unsigned long long>(entry));
  }

  // Polls for end-of-computation, bounded by `timeout_cycles` sys-clock
  // cycles. Returns the program's exit code, or -1 on timeout.
  int WaitForEoc(uint64_t timeout_cycles) {
    uint32_t sbcs = dm::kSbcsSbreadonaddr | dm::sbcs_access(2);
    DmiWrite(dm::kSbcs, sbcs);
    SbaWaitIdle();
    uint64_t addr = dm::kAmRegs + dm::kCheshireScratch2Offset;
    DmiWrite(dm::kSbAddress1, uint32_t(addr >> 32));
    uint32_t data;
    do {
      if (sys_cycles_ > timeout_cycles) {
        fprintf(stderr, "[TB] TIMEOUT: exceeded %llu sys-clock cycles waiting for end-of-computation\n",
                static_cast<unsigned long long>(timeout_cycles));
        return -1;
      }
      DmiWrite(dm::kSbAddress0, uint32_t(addr & 0xFFFFFFFFu));
      JtagIdleCycles(800);
      data = DmiRead(dm::kSbData0);
    } while (!(data & 1));
    return int(data >> 1);
  }

 private:
  // Central time-wheel: advances simulated time by `delta_ps`, toggling
  // the free-running sys clock, RTC, and UART oversample tick whenever
  // they come due, evaluating the model immediately after any of them
  // changes. This is what lets a JTAG driver call block for many
  // microseconds of idle-cycle waiting while the SoC's own clock (and the
  // UART sampler) keep running underneath it.
  void AdvanceTime(uint64_t delta_ps) {
    uint64_t target = now_ps_ + delta_ps;
    while (now_ps_ < target) {
      uint64_t next = std::min({next_clk_ps_, next_rtc_ps_, next_uart_ps_, target});
      if (next > now_ps_) {
        contextp_->timeInc(next - now_ps_);
        now_ps_ = next;
      }
      bool changed = false;
      if (now_ps_ == next_clk_ps_) {
        clk_level_ = !clk_level_;
        top_->clk_i = clk_level_;
        if (clk_level_) ++sys_cycles_;
        next_clk_ps_ += sys_half_ps_;
        changed = true;
      }
      if (now_ps_ == next_rtc_ps_) {
        rtc_level_ = !rtc_level_;
        top_->rtc_i = rtc_level_;
        next_rtc_ps_ += rtc_half_ps_;
        changed = true;
      }
      if (changed) top_->eval();
      if (now_ps_ == next_uart_ps_) {
        uart_rx_.Sample(top_->uart_tx_o & 1);
        next_uart_ps_ += uart_sample_ps_;
      }
    }
  }

  VerilatedContext *contextp_;
  Vnewt_verilator_top *top_;

  uint64_t now_ps_ = 0;
  uint64_t sys_half_ps_, rtc_half_ps_, jtag_half_ps_, uart_sample_ps_;
  uint64_t next_clk_ps_ = 0, next_rtc_ps_ = 0, next_uart_ps_ = 0;
  bool clk_level_ = false, rtc_level_ = false;
  uint64_t sys_cycles_ = 0;
  UartRx uart_rx_;
};

// ==========================================================================
// main: plusarg parsing, ELF load, and the end-to-end run
// ==========================================================================

static const char *ValueAfter(const std::string &arg, const char *prefix) {
  size_t n = strlen(prefix);
  return arg.compare(0, n, prefix) == 0 ? arg.c_str() + n : nullptr;
}

int main(int argc, char **argv) {
  auto contextp = std::make_unique<VerilatedContext>();
  contextp->commandArgs(argc, argv);
  auto top = std::make_unique<Vnewt_verilator_top>(contextp.get());

  std::string binary_path;
  int bootmode = 0;
  int prelmode = 0;
  uint64_t timeout_cycles = 20'000'000;  // ~200us of simulated time at 100MHz
  uint32_t uart_baud = 115200;           // sw/tests/helloworld.c's __BOOT_BAUDRATE

  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    if (auto v = ValueAfter(a, "+BINARY="))
      binary_path = v;
    else if (auto v = ValueAfter(a, "+BOOTMODE="))
      bootmode = atoi(v);
    else if (auto v = ValueAfter(a, "+PRELMODE="))
      prelmode = atoi(v);
    else if (auto v = ValueAfter(a, "+TIMEOUT_CYCLES="))
      timeout_cycles = strtoull(v, nullptr, 10);
    else if (auto v = ValueAfter(a, "+UART_BAUD="))
      uart_baud = uint32_t(atoi(v));
  }

  if (binary_path.empty()) {
    fprintf(stderr, "[TB] ERROR: +BINARY=<elf path> is required\n");
    return 1;
  }

  // This lane wires the harness's boot_mode straight to SPM (0) and drives
  // ELF preload over JTAG/SBA - see design.md D1/D4. Reject anything else
  // clearly instead of silently ignoring it or hanging (spec: "Unsupported
  // configuration is rejected clearly").
  if (bootmode != 0) {
    fprintf(stderr,
            "[TB] ERROR: unsupported BOOTMODE=%d - this lane only supports SPM boot (BOOTMODE=0)\n",
            bootmode);
    return 1;
  }
  if (prelmode != 0) {
    fprintf(stderr,
            "[TB] ERROR: unsupported PRELMODE=%d - this lane only supports JTAG preload (PRELMODE=0)\n",
            prelmode);
    return 1;
  }

  elf::Image img;
  if (!elf::load(binary_path, img)) return 1;
  printf("[TB] Loaded %s: entry=0x%llx, %zu segment(s)\n", binary_path.c_str(),
         static_cast<unsigned long long>(img.entry), img.segments.size());

  Tb tb(contextp.get(), top.get(), uart_baud);
  tb.Reset(20);  // RstCycles=20, matches target/sim/src/fixture_iguana.sv
  tb.JtagInit();
  tb.HaltAndLoad(img);
  tb.SetDpcAndResume(img.entry);

  int code = tb.WaitForEoc(timeout_cycles);

  top->final();

  if (code < 0) return 1;  // timeout
  if (code != 0) {
    fprintf(stderr, "[TB] Test FAILED: exit code %d\n", code);
    return code;
  }
  printf("[TB] Test PASSED (exit code 0, %llu sys-clock cycles)\n",
         static_cast<unsigned long long>(tb.sys_cycles()));
  return 0;
}
