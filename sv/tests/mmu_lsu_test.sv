// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_lsu_test.sv
//
// LSU (data) translation smoke test. Starts mmu_lsu_seq on the env virtual
// sequencer: PageTableSV generates a page table live in-sim, preloads it into
// sysmem + Whisper, programs satp, and drives data loads AND stores across both
// fast pipes (pipe0/pipe1). The mmu_scoreboard compares each translation
// against Whisper.
//
// Scope: NO-FAULT page tables only (stores land on valid writable pages, so no
// permission/dirty faults). Fault injection is a later session. Recommended:
//   make run TEST=mmu_lsu_test +PT_DYNAMIC +PT_NO_FAULT +PT_SEED=7
//   make run TEST=mmu_lsu_test            (static no-fault config, seed 1)
//======================================================================
`ifndef MMU_LSU_TEST_SV
`define MMU_LSU_TEST_SV

class mmu_lsu_test extends mmu_base_test;
  `uvm_component_utils(mmu_lsu_test)

  function new(string name = "mmu_lsu_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    mmu_lsu_seq seq;
    phase.raise_objection(this, "lsu smoke running");
    // Drain so the LSU monitor flushes its last transaction: access_fault is
    // a registered DUT output (1-deep pipeline in mmu_lsu_monitor.sv), so the
    // final response publishes one cycle after its driver handshake. Mirrors
    // mmu_ifu_test.
    phase.phase_done.set_drain_time(this, 100ns);
    seq = mmu_lsu_seq::type_id::create("seq");
    // num_of_reqs=0 => randomized 1000..3000 total, driven in
    // ~300-400 batches over the pool WITH REPLACEMENT. Override +MMU_NUM_REQS.
    seq.store_pct = 40;      // load/store mix (stores hit valid writable pages)
    seq.start(env.vseqr);

    phase.drop_objection(this, "lsu smoke done");
  endtask

endclass : mmu_lsu_test

`endif // MMU_LSU_TEST_SV
