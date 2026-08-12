// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_csr_agent.sv
//
// CSR / CP0 agent. Always builds the monitor; builds the driver + sequencer
// when UVM_ACTIVE and connects them. Active by default; env can make it
// passive via config_db ("is_active"). Components fetch the shared mmu_vif
// from config_db themselves (no per-agent config object).
//======================================================================
`ifndef MMU_CSR_AGENT_SV
`define MMU_CSR_AGENT_SV

class mmu_csr_agent extends uvm_agent;
  `uvm_component_utils(mmu_csr_agent)

  mmu_csr_driver    drv;
  mmu_csr_monitor   mon;
  mmu_csr_sequencer sqr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = mmu_csr_monitor::type_id::create("mon", this);
    if (get_is_active() == UVM_ACTIVE) begin
      drv = mmu_csr_driver   ::type_id::create("drv", this);
      sqr = mmu_csr_sequencer::type_id::create("sqr", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (get_is_active() == UVM_ACTIVE)
      drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction

endclass : mmu_csr_agent

`endif // MMU_CSR_AGENT_SV
