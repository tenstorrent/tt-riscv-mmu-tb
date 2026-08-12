// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_csr_cfg_seq.sv
//
// One-shot configuration sequence for the CSR/CP0 agent:
//   1) CTX_SET  — put the core in Supervisor mode (translation active),
//                 PTW enabled, MXR/SUM off.
//   2) REG_WRITE SATP — enable Sv39 with the root PPN from the loader.
//
// satp_ppn/asid are set by the test before start(). ASID defaults to 0x100.
//======================================================================

`ifndef MMU_CSR_CFG_SEQ_SV
`define MMU_CSR_CFG_SEQ_SV

class mmu_csr_cfg_seq extends uvm_sequence #(mmu_csr_seq_item);
  `uvm_object_utils(mmu_csr_cfg_seq)

  bit [27:0] satp_ppn = '0;
  bit [15:0] asid     = 16'h100;
  bit        sv39_en  = 1'b1;
  // When set, the CTX_SET first waits for the MMU to go quiescent
  // (mmu_yy_xx_no_op) before applying the new context -- used by the
  // dynamic-satp sequence, which swaps the translation context mid-run.
  bit        wait_idle = 1'b0;

  function new(string name = "mmu_csr_cfg_seq");
    super.new(name);
  endfunction

  virtual task body();
    mmu_csr_seq_item ctx, satp;

    // 1) Supervisor mode, PTW enabled.
    ctx = mmu_csr_seq_item::type_id::create("ctx");
    start_item(ctx);
    ctx.op        = mmu_csr_seq_item::CTX_SET;
    ctx.priv_mode = 2'b01;      // S-mode
    ctx.mprv      = 1'b0;
    ctx.mpp       = 2'b00;
    ctx.mxr       = 1'b0;
    ctx.sum       = 1'b0;
    ctx.ptw_en    = 1'b1;
    ctx.maee      = 1'b0;
    ctx.cskyee    = 1'b0;
    ctx.wait_idle = wait_idle;   // dynamic-satp: quiesce before swapping context
    finish_item(ctx);

    // 2) satp = {Sv39, ASID, PPN}.
    satp = mmu_csr_seq_item::type_id::create("satp");
    start_item(satp);
    satp.op    = mmu_csr_seq_item::REG_WRITE;
    satp.sel   = mmu_csr_seq_item::SATP;
    satp.wdata = mmu_csr_seq_item::pack_satp(sv39_en, asid, satp_ppn);
    finish_item(satp);

    `uvm_info("CSR_CFG",
      $sformatf("satp programmed: sv39=%0b asid=0x%0h ppn=0x%0h", sv39_en, asid, satp_ppn),
      UVM_LOW)
  endtask

endclass : mmu_csr_cfg_seq

`endif // MMU_CSR_CFG_SEQ_SV
