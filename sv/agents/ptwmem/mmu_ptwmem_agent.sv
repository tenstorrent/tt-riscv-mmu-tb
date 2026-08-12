// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_ptwmem_agent.sv
//
// PTW memory-bus agent. Wraps the responder that serves page-table reads
// from the shared mmu_sysmem. Always active (the DUT always needs its
// PTE reads answered). Responder-only: PTE traffic is not published to the
// scoreboard, which re-walks the tables itself when it needs walk visibility.
//======================================================================

`ifndef MMU_PTWMEM_AGENT_SV
`define MMU_PTWMEM_AGENT_SV

class mmu_ptwmem_agent extends uvm_agent;
  `uvm_component_utils(mmu_ptwmem_agent)

  mmu_ptwmem_responder resp;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    resp = mmu_ptwmem_responder::type_id::create("resp", this);
  endfunction

endclass : mmu_ptwmem_agent

`endif // MMU_PTWMEM_AGENT_SV
