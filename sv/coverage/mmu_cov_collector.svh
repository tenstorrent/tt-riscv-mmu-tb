// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_cov_collector.svh
//
// Functional coverage collector. Subscribes to the scoreboard's
// resolved-translation stream (mmu_xlate_result) and samples the MMU
// covergroups. Built by the env only when coverage is enabled
// (+define+MMU_COVERAGE); compiled out otherwise so non-coverage and
// Verilator lint flows are unaffected.
//
// Included inside mmu_coverage_pkg.
//======================================================================
`ifndef MMU_COV_COLLECTOR_SVH
`define MMU_COV_COLLECTOR_SVH

  class mmu_cov_collector extends uvm_subscriber #(mmu_xlate_result);
    `uvm_component_utils(mmu_cov_collector)

    mmu_paging_cov paging;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      paging = mmu_paging_cov::type_id::create("paging");
    endfunction

    // uvm_subscriber analysis write.
    virtual function void write(mmu_xlate_result t);
      paging.sample(t);
    endfunction
  endclass : mmu_cov_collector

`endif // MMU_COV_COLLECTOR_SVH