// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_ifu_lsu_test.sv
//
// Combined IFU + LSU translation smoke test. Starts mmu_ifu_lsu_seq: it does
// the one-time shared setup (page tables -> sysmem+Whisper -> satp), then forks
// the IFU (fetch) and LSU (load/store, both pipes) drive phases CONCURRENTLY
// against the same page tables / PMP config / satp. The mmu_scoreboard checks
// both streams against Whisper (+ the TB PMP/walk predictors).
//
// Fixed privilege (S) for the run: the two sub-sequences share the priv pin so
// they don't race on it. Coordinated mid-run priv/satp switching lives in
// mmu_dynamic_satp_test (see mmu_dynamic_satp_seq).
//   make run TEST=mmu_ifu_lsu_test +PT_DYNAMIC +PT_SEED=7
//======================================================================
`ifndef MMU_IFU_LSU_TEST_SV
`define MMU_IFU_LSU_TEST_SV

class mmu_ifu_lsu_test extends mmu_base_test;
  `uvm_component_utils(mmu_ifu_lsu_test)

  function new(string name = "mmu_ifu_lsu_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    mmu_ifu_lsu_seq seq;
    phase.raise_objection(this, "ifu+lsu smoke running");
    // Drain so the IFU deny / LSU access_fault (registered DUT outputs) flush.
    phase.phase_done.set_drain_time(this, 100ns);
    seq = mmu_ifu_lsu_seq::type_id::create("seq");
    // num_of_reqs=0 => randomized 1000..3000 per interface,
    // IFU + LSU driven concurrently. Override +MMU_NUM_REQS.
    seq.store_pct = 40;
    seq.start(env.vseqr);
    phase.drop_objection(this, "ifu+lsu smoke done");
  endtask

endclass : mmu_ifu_lsu_test

`endif // MMU_IFU_LSU_TEST_SV
