// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_pmp_agent.sv
//
// PMP config-manager agent. Always builds the monitor; builds the driver +
// sequencer when UVM_ACTIVE and connects them, mirroring mmu_ifu_agent /
// mmu_lsu_agent. Single sequencer -- one config bus. Active by default; the
// driver fetches the shared mmu_vif from config_db itself (the monitor
// doesn't touch the DUT boundary), per house style -- no per-agent config
// object.
//======================================================================
`ifndef MMU_PMP_AGENT_SV
`define MMU_PMP_AGENT_SV

class mmu_pmp_agent extends uvm_agent;
  `uvm_component_utils(mmu_pmp_agent)

  mmu_pmp_driver    drv;
  mmu_pmp_monitor   mon;
  mmu_pmp_sequencer sqr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = mmu_pmp_monitor::type_id::create("mon", this);
    if (get_is_active() == UVM_ACTIVE) begin
      drv = mmu_pmp_driver   ::type_id::create("drv", this);
      sqr = mmu_pmp_sequencer::type_id::create("sqr", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (get_is_active() == UVM_ACTIVE) begin
      drv.seq_item_port.connect(sqr.seq_item_export);
      drv.cfg_ap.connect(mon.analysis_export);
    end
  endfunction

endclass : mmu_pmp_agent

`endif // MMU_PMP_AGENT_SV
