// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_virtual_sequencer.sv
//
// Env-level virtual sequencer.
// It holds handles to the per-agent sequencers and the shared memory model so a
// virtual sequence (mmu_base_seq) can orchestrate the whole flow via
// p_sequencer without the test threading collaborators in by hand. The env
// connects these handles in connect_phase.
//======================================================================

`ifndef MMU_VIRTUAL_SEQUENCER_SV
`define MMU_VIRTUAL_SEQUENCER_SV

class mmu_virtual_sequencer extends uvm_sequencer;
  `uvm_component_utils(mmu_virtual_sequencer)

  // Sub-agent sequencers + shared memory, connected by the env.
  mmu_csr_sequencer csr_sqr;
  mmu_ifu_sequencer ifu_sqr;
  mmu_lsu_sequencer lsu_sqr0;   // pipe0
  mmu_lsu_sequencer lsu_sqr1;   // pipe1
  mmu_pmp_sequencer pmp_sqr;    // PMP config-manager (base seq applies a config)
  mmu_tlb_inv_sequencer inv_sqr; // TLB-invalidation (sfence.vma) agent
  mmu_sysmem        mem;
  // LSU outstanding-id pool (shared with the LSU driver), for back-pressure.
  mmu_lsu_idbuf     idbuf;
  // Whisper reference model — base seq mirrors PTEs + satp into it.
  whisper_dv_mmu    wh;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

endclass : mmu_virtual_sequencer

`endif // MMU_VIRTUAL_SEQUENCER_SV
