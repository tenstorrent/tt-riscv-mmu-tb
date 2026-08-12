// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_csr_reg_test.sv
//
// Existential test for the T-Head MMU registers SMIR/SMEL/SMEH/SMCIR:
// reset value + write/read-back per register. Self-checking, no page tables
// and no translation traffic.
//======================================================================
`ifndef MMU_CSR_REG_TEST_SV
`define MMU_CSR_REG_TEST_SV

class mmu_csr_reg_test extends mmu_base_test;
  `uvm_component_utils(mmu_csr_reg_test)

  function new(string name = "mmu_csr_reg_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    mmu_csr_reg_seq seq;
    phase.raise_objection(this, "csr reg test running");
    seq = mmu_csr_reg_seq::type_id::create("seq");
    seq.start(env.vseqr.csr_sqr);
    phase.drop_objection(this, "csr reg test done");
  endtask

endclass : mmu_csr_reg_test

`endif // MMU_CSR_REG_TEST_SV
