// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_csr_reg_seq.sv
//
// Existential check of the four T-Head MMU registers (SMIR/SMEL/SMEH/SMCIR):
// reset value, then write -> read-back -> compare, per register.
//
// Register-file only -- no TLB operation is issued. cskyee stays 0, so the
// SMCIR op bits decode to nothing (ct_mmu_regs.v ANDs each op with cskyee);
// the sequence asserts they read back 0, and only exercises SMCIR's ASID.
//======================================================================
`ifndef MMU_CSR_REG_SEQ_SV
`define MMU_CSR_REG_SEQ_SV

class mmu_csr_reg_seq extends uvm_sequence #(mmu_csr_seq_item);
  `uvm_object_utils(mmu_csr_reg_seq)

  int unsigned num_random = 4;   // random patterns per register, after the directed ones

  function new(string name = "mmu_csr_reg_seq");
    super.new(name);
  endfunction

  // Bits that survive a write->read round trip. Everything else in the
  // readback is reserved-zero or read-only status, so it is masked off.
  //   SMIR  [11:0]  index          ([31:30] = probe/tfatal, read-only)
  //   SMEL  [63:59] SO/C/B/SH/Sec, [37:0] PPN/RSW/D/A/G/U/X/W/R/V ([58:38] rsvd)
  //   SMEH  [45:19] VPN, [18:16] page size, [15:0] ASID
  //   SMCIR [15:0]  ASID           (op bits [31:26] are gated off by cskyee=0)
  protected function bit [63:0] rw_mask(mmu_csr_seq_item::csr_sel_e s);
    case (s)
      mmu_csr_seq_item::MIR : return 64'h0000_0000_0000_0FFF;
      mmu_csr_seq_item::MEL : return 64'hF800_003F_FFFF_FFFF;
      mmu_csr_seq_item::MEH : return 64'h0000_3FFF_FFFF_FFFF;
      mmu_csr_seq_item::MCIR: return 64'h0000_0000_0000_FFFF;
      default               : return 64'h0;
    endcase
  endfunction

  protected task wr(mmu_csr_seq_item::csr_sel_e s, bit [63:0] data);
    mmu_csr_seq_item it = mmu_csr_seq_item::type_id::create("wr");
    start_item(it);
    it.op = mmu_csr_seq_item::REG_WRITE;  it.sel = s;  it.wdata = data;
    finish_item(it);
  endtask

  protected task rd(mmu_csr_seq_item::csr_sel_e s, output bit [63:0] data);
    mmu_csr_seq_item it = mmu_csr_seq_item::type_id::create("rd");
    start_item(it);
    it.op = mmu_csr_seq_item::REG_READ;  it.sel = s;
    finish_item(it);
    data = it.rdata;
  endtask

  // Write a pattern, read it back, compare only the writable bits.
  protected task check(mmu_csr_seq_item::csr_sel_e s, bit [63:0] pat, string tag);
    bit [63:0] got, m = rw_mask(s);
    wr(s, pat);
    rd(s, got);
    if ((got & m) !== (pat & m))
      `uvm_error("CSR_REG_SEQ",
        $sformatf("%s %s: wrote 0x%016h, read 0x%016h (masked exp 0x%016h got 0x%016h)",
                  s.name(), tag, pat, got, pat & m, got & m))
    else
      `uvm_info("CSR_REG_SEQ",
        $sformatf("%s %s: 0x%016h -> 0x%016h OK", s.name(), tag, pat, got), UVM_MEDIUM)
  endtask

  virtual task body();
    mmu_csr_seq_item::csr_sel_e regs[4];
    bit [63:0] got;
    regs = '{mmu_csr_seq_item::MIR,  mmu_csr_seq_item::MEL,
             mmu_csr_seq_item::MEH,  mmu_csr_seq_item::MCIR};

    foreach (regs[i]) begin
      // Reset value: all four clear to 0 on cpurst_b.
      rd(regs[i], got);
      if ((got & rw_mask(regs[i])) !== 64'h0)
        `uvm_error("CSR_REG_SEQ",
          $sformatf("%s reset value not 0: 0x%016h", regs[i].name(), got))

      check(regs[i], 64'hFFFF_FFFF_FFFF_FFFF, "all-ones");
      check(regs[i], 64'h0,                   "all-zeros");
      // Walking ones -- catches a swapped or stuck bit, which a
      // solid-pattern test cannot.
      for (int b = 0; b < 64; b++)
        if (rw_mask(regs[i])[b]) check(regs[i], (64'h1 << b), $sformatf("bit%0d", b));
      for (int unsigned r = 0; r < num_random; r++)
        check(regs[i], {$urandom(), $urandom()}, "random");
    end

    // cskyee=0 must leave every SMCIR op bit clear even when written.
    wr(mmu_csr_seq_item::MCIR, 64'h0000_0000_FC00_0000);   // [31:26] = all ops
    rd(mmu_csr_seq_item::MCIR, got);
    if (got[31:26] !== 6'b0)
      `uvm_error("CSR_REG_SEQ",
        $sformatf("SMCIR op bits set with cskyee=0: rdata[31:26]=0x%0h", got[31:26]))
  endtask

endclass : mmu_csr_reg_seq

`endif // MMU_CSR_REG_SEQ_SV
