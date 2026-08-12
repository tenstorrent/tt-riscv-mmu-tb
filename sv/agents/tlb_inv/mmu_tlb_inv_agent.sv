// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_tlb_inv_agent.sv
//======================================================================
`ifndef MMU_TLB_INV_AGENT_SV
`define MMU_TLB_INV_AGENT_SV

class mmu_tlb_inv_agent extends uvm_agent;
  `uvm_component_utils(mmu_tlb_inv_agent)

  mmu_tlb_inv_sequencer sqr;
  mmu_tlb_inv_driver    drv;
  mmu_tlb_inv_monitor   mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = mmu_tlb_inv_monitor::type_id::create("mon", this);
    if (get_is_active() == UVM_ACTIVE) begin
      sqr = mmu_tlb_inv_sequencer::type_id::create("sqr", this);
      drv = mmu_tlb_inv_driver::type_id::create("drv", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (get_is_active() == UVM_ACTIVE)
      drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction

endclass : mmu_tlb_inv_agent

`endif // MMU_TLB_INV_AGENT_SV
