// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_ifu_test.sv
//
// IFU translation smoke test. Starts mmu_ifu_seq on the env virtual
// sequencer: PageTableSV generates a page table live in-sim (riescue via
// pysv/DPI, no container), preloads it into the mem model, programs satp, and
// drives IFU fetch translations. The sequence itself only checks that each
// fetch translated; PA/fault correctness is scored by mmu_scoreboard against
// the Whisper reference model.
//
// Run: make run TEST=mmu_ifu_test [PT_CONFIG=<cfg> PT_SEED=<n>]
//======================================================================

`ifndef MMU_IFU_TEST_SV
`define MMU_IFU_TEST_SV

class mmu_ifu_test extends mmu_base_test;
  `uvm_component_utils(mmu_ifu_test)

  function new(string name = "mmu_ifu_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    mmu_ifu_seq seq;
    phase.raise_objection(this, "ifu smoke running");
    // Drain so the IFU monitor flushes its last transaction (deny is registered).
    phase.phase_done.set_drain_time(this, 100ns);

    seq = mmu_ifu_seq::type_id::create("seq");
    seq.start(env.vseqr);

    phase.drop_objection(this, "ifu smoke done");
  endtask

endclass : mmu_ifu_test

`endif // MMU_IFU_TEST_SV
