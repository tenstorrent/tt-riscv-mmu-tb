// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_dynamic_satp_test.sv
//
// Dynamic satp context-switch test: 5-7 context switches, each with an update
// type (weighted ASID/PPN/MODE), a spec-correct invalidation
// (INV_ASID / INV_ALL / none), a fresh page table (except ASID-only), rare
// PMP/PMA re-randomization, and a full translation batch. Dynamic-only
// (+PT_DYNAMIC). Global pages optional via +MMU_SATP_ENABLE_GLOBAL_PAGES.
//======================================================================
`ifndef MMU_DYNAMIC_SATP_TEST_SV
`define MMU_DYNAMIC_SATP_TEST_SV

class mmu_dynamic_satp_test extends mmu_base_test;
  `uvm_component_utils(mmu_dynamic_satp_test)

  function new(string name = "mmu_dynamic_satp_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    mmu_dynamic_satp_seq seq;
    phase.raise_objection(this, "dynamic satp");
    phase.phase_done.set_drain_time(this, 200ns);
    seq = mmu_dynamic_satp_seq::type_id::create("seq");
    seq.start(env.vseqr);
    phase.drop_objection(this, "dynamic satp done");
  endtask

endclass : mmu_dynamic_satp_test

`endif // MMU_DYNAMIC_SATP_TEST_SV
