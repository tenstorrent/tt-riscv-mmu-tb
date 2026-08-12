// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_tlb_inv_seq_item.sv
//
// One TLB-invalidation request (sfence.vma variant or the CP0 full flush).
// The C910 iuTLB/duTLB store no ASID/global, so ASID/global scoping is a
// jTLB-only property (see the checker); the item still carries asid/vpn for the
// jTLB reference model and for driving the operand pins.
//======================================================================
`ifndef MMU_TLB_INV_SEQ_ITEM_SV
`define MMU_TLB_INV_SEQ_ITEM_SV

typedef enum bit [2:0] {
  INV_ALL,       // rs1=0,rs2=0   -> lsu_mmu_tlb_all_inv      (flush everything)
  INV_ASID,      // rs1=0,rs2!=0  -> lsu_mmu_tlb_asid_all_inv (by ASID, global survives)
  INV_VA,        // rs1!=0,rs2=0  -> lsu_mmu_tlb_va_all_inv   (by VA, any ASID)
  INV_VA_ASID,   // rs1!=0,rs2!=0 -> lsu_mmu_tlb_va_asid_inv  (by VA + ASID)
  INV_CP0_ALL    // SMCIR TLBIALL -> cp0_mmu_tlb_all_inv      (flush everything)
} mmu_inv_kind_e;

class mmu_tlb_inv_seq_item extends uvm_sequence_item;

  rand mmu_inv_kind_e kind;
  rand bit [26:0]     vpn;    // used by INV_VA / INV_VA_ASID (va[38:12])
  rand bit [15:0]     asid;   // used by INV_ASID / INV_VA_ASID

  // Observed by the monitor: cycles from strobe to mmu_lsu_tlb_inv_done.
  int unsigned        done_latency;

  `uvm_object_utils_begin(mmu_tlb_inv_seq_item)
    `uvm_field_enum(mmu_inv_kind_e, kind, UVM_ALL_ON)
    `uvm_field_int (vpn,          UVM_ALL_ON)
    `uvm_field_int (asid,         UVM_ALL_ON)
    `uvm_field_int (done_latency, UVM_ALL_ON | UVM_NOCOMPARE)
  `uvm_object_utils_end

  function new(string name = "mmu_tlb_inv_seq_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("%s vpn=0x%0h asid=0x%0h done_lat=%0d",
                     kind.name(), vpn, asid, done_latency);
  endfunction

endclass : mmu_tlb_inv_seq_item

`endif // MMU_TLB_INV_SEQ_ITEM_SV
