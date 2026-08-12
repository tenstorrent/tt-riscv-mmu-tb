// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_ifu_agent.sv
//
// IFU (instruction-fetch) translation agent. Always builds the monitor;
// builds the driver + sequencer when UVM_ACTIVE and connects them. Active
// by default; the env can make it passive via config_db ("is_active").
// The driver/monitor fetch the shared mmu_vif from config_db themselves
// (no per-agent config object, per house style).
//======================================================================
`ifndef MMU_IFU_AGENT_SV
`define MMU_IFU_AGENT_SV

class mmu_ifu_agent extends uvm_agent;
  `uvm_component_utils(mmu_ifu_agent)

  mmu_ifu_driver    drv;
  mmu_ifu_monitor   mon;
  mmu_ifu_sequencer sqr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = mmu_ifu_monitor::type_id::create("mon", this);
    if (get_is_active() == UVM_ACTIVE) begin
      drv = mmu_ifu_driver   ::type_id::create("drv", this);
      sqr = mmu_ifu_sequencer::type_id::create("sqr", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (get_is_active() == UVM_ACTIVE)
      drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction

endclass : mmu_ifu_agent

`endif // MMU_IFU_AGENT_SV
