// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_base_test.sv
//
// Base UVM test. Brings up UVM, raises/drops an objection so the TB-top reset
// sequence completes, and exits cleanly. Derived tests build the env and start
// sequences.
//======================================================================

`ifndef MMU_BASE_TEST_SV
`define MMU_BASE_TEST_SV

class mmu_base_test extends uvm_test;
  `uvm_component_utils(mmu_base_test)

  mmu_env env;

  function new(string name = "mmu_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = mmu_env::type_id::create("env", this);
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this, "mmu_base_test running");
    `uvm_info(get_type_name(), "OpenC910 MMU testbench brought up (env built).", UVM_LOW)
    #1us;
    phase.drop_objection(this, "mmu_base_test done");
  endtask

endclass : mmu_base_test

`endif // MMU_BASE_TEST_SV
