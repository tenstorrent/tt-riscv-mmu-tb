// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_lsu_agent.sv
//
// LSU (data load/store) translation agent. Always builds the monitor; builds
// the driver + sequencer when UVM_ACTIVE and connects them. Active by default;
// the env can make it passive via config_db ("is_active"). The driver/monitor
// fetch the shared mmu_vif (and the driver the mmu_lsu_idbuf) from config_db
// themselves — no per-agent config object, per house style.
//======================================================================
`ifndef MMU_LSU_AGENT_SV
`define MMU_LSU_AGENT_SV

class mmu_lsu_agent extends uvm_agent;
  `uvm_component_utils(mmu_lsu_agent)

  mmu_lsu_driver    drv;
  mmu_lsu_monitor   mon;
  mmu_lsu_sequencer sqr0;   // feeds pipe0
  mmu_lsu_sequencer sqr1;   // feeds pipe1

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = mmu_lsu_monitor::type_id::create("mon", this);
    if (get_is_active() == UVM_ACTIVE) begin
      drv  = mmu_lsu_driver   ::type_id::create("drv", this);
      sqr0 = mmu_lsu_sequencer::type_id::create("sqr0", this);
      sqr1 = mmu_lsu_sequencer::type_id::create("sqr1", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (get_is_active() == UVM_ACTIVE) begin
      drv.seq_item_port .connect(sqr0.seq_item_export);
      drv.seq_item_port1.connect(sqr1.seq_item_export);
    end
  endfunction

endclass : mmu_lsu_agent

`endif // MMU_LSU_AGENT_SV
