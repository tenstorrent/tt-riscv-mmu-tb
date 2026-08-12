// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_csr_seq_item.sv
//
// Transaction for the CSR / CP0 agent. Generic register write:
//
//   op = REG_WRITE : pulse a register write. `sel` picks the register
//                    (SATP -> cp0_mmu_satp_sel; MIR/MEL/MEH/MCIR ->
//                    cp0_mmu_reg_num), `wdata` is the value; driver waits
//                    for mmu_cp0_cmplt. Sequence composes satp `wdata` via
//                    pack_satp().
//   op = CTX_SET  : update the *level* priv/mstatus/enable pins (these are
//                    dedicated inputs on C910, not CSR-writable).
//
// SATP + CTX_SET cover the translation context; the reg_num-selected T-Head
// regs (SMIR/SMEL/SMEH/SMCIR) use the same REG_WRITE path.
//======================================================================
`ifndef MMU_CSR_SEQ_ITEM_SV
`define MMU_CSR_SEQ_ITEM_SV

class mmu_csr_seq_item extends uvm_sequence_item;

  // REG_READ: hold reg_num with wreg=0 and sample mmu_cp0_data (a
  // combinational mux on reg_num -- no read strobe exists).
  typedef enum bit [1:0] { REG_WRITE, CTX_SET, REG_READ } op_e;
  typedef enum bit [2:0] { SATP, MIR, MEL, MEH, MCIR } csr_sel_e;

  rand op_e op;

  // ---- REG_WRITE ----
  rand csr_sel_e   sel;
  rand bit [63:0]  wdata;

  // ---- CTX_SET (level priv / mstatus / enable pins) ----
  rand bit [1:0]   priv_mode;   // 00=U, 01=S, 11=M
  rand bit         mprv;
  rand bit [1:0]   mpp;
  rand bit         mxr;
  rand bit         sum;
  rand bit         ptw_en;
  rand bit         maee;
  rand bit         cskyee;
  // When set on a CTX_SET, the driver first waits for the MMU to go quiescent
  // (mmu_yy_xx_no_op) before applying the context. Used by the dynamic-satp
  // sequence, which must swap the translation context only between translations.
  bit              wait_idle;

  // ---- response (captured) ----
  logic            cmplt;       // mmu_cp0_cmplt
  logic [63:0]     rdata;       // mmu_cp0_data / mmu_cp0_satp_data readback
  logic            mmu_en;      // mmu_xx_mmu_en observed

  `uvm_object_utils_begin(mmu_csr_seq_item)
    `uvm_field_enum(op_e,      op,        UVM_ALL_ON)
    `uvm_field_enum(csr_sel_e, sel,       UVM_ALL_ON)
    `uvm_field_int (wdata,     UVM_ALL_ON | UVM_HEX)
    `uvm_field_int (priv_mode, UVM_ALL_ON)
    `uvm_field_int (mprv,      UVM_ALL_ON)
    `uvm_field_int (mpp,       UVM_ALL_ON)
    `uvm_field_int (mxr,       UVM_ALL_ON)
    `uvm_field_int (sum,       UVM_ALL_ON)
    `uvm_field_int (ptw_en,    UVM_ALL_ON)
    `uvm_field_int (maee,      UVM_ALL_ON)
    `uvm_field_int (cskyee,    UVM_ALL_ON)
    `uvm_field_int (cmplt,     UVM_ALL_ON)
    `uvm_field_int (rdata,     UVM_ALL_ON | UVM_HEX)
    `uvm_field_int (mmu_en,    UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "mmu_csr_seq_item");
    super.new(name);
  endfunction

  // Compose a C910 satp write value from decoded fields.
  // Layout (ct_mmu_regs.v): [63]=mode-enable(1=Sv39), [59:44]=ASID, [27:0]=PPN.
  static function bit [63:0] pack_satp(bit sv39_en, bit [15:0] asid, bit [27:0] ppn);
    return {sv39_en, 3'b0, asid, 16'b0, ppn};
  endfunction

  virtual function string convert2string();
    if (op == REG_WRITE)
      return $sformatf("CSR REG_WRITE sel=%s wdata=0x%0h -> cmplt=%0b rdata=0x%0h",
                       sel.name(), wdata, cmplt, rdata);
    else
      return $sformatf("CSR CTX_SET priv=%0d mprv=%0b mpp=%0d mxr=%0b sum=%0b ptw_en=%0b maee=%0b cskyee=%0b -> mmu_en=%0b",
                       priv_mode, mprv, mpp, mxr, sum, ptw_en, maee, cskyee, mmu_en);
  endfunction

endclass : mmu_csr_seq_item

`endif // MMU_CSR_SEQ_ITEM_SV
