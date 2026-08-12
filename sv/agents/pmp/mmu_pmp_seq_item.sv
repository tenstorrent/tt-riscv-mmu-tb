// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_pmp_seq_item.sv
//
// Transaction for the PMP config-manager agent. Carries one full 16-entry
// PMP config to be written into the interface's combinational responder
// (mmu_if.pmp_cfg). There is no DUT request/response to capture:
// this agent configures the PMP model, it does not drive/observe a DUT port.
//======================================================================
`ifndef MMU_PMP_SEQ_ITEM_SV
`define MMU_PMP_SEQ_ITEM_SV

class mmu_pmp_seq_item extends uvm_sequence_item;

  // The config to apply. rand + constructed in new() so a plain randomize()
  // on this item also (re-)randomizes the nested config object (nested
  // rand-object semantics); most callers instead build/mutate cfg directly
  // (e.g. cfg.set_all_permissive()) and skip randomize() altogether.
  rand mmu_pmp_config cfg;

  `uvm_object_utils_begin(mmu_pmp_seq_item)
    `uvm_field_object(cfg, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "mmu_pmp_seq_item");
    super.new(name);
    cfg = mmu_pmp_config::type_id::create("cfg");
  endfunction

  virtual function string convert2string();
    return $sformatf(
      "PMP apply cfg=%s entry0={vld=%0b lo=0x%0h hi=0x%0h r=%0b w=%0b x=%0b l=%0b}",
      cfg.get_name(), cfg.vld[0], cfg.lo[0], cfg.hi[0], cfg.r[0], cfg.w[0], cfg.x[0], cfg.l[0]);
  endfunction

endclass : mmu_pmp_seq_item

`endif // MMU_PMP_SEQ_ITEM_SV
