// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_coverage_pkg.sv
//
// MMU functional-coverage package. Leaf package (depends only on uvm_pkg):
// holds the resolved-translation event type, the covergroups, and the
// collector. Imported by mmu_checkers_pkg (for the event type emitted by
// the scoreboard) and by mmu_env_pkg (to build the collector).
//
// The covergroup bodies port the corearchcoverage coverpoint/bin content
// but bind it to explicit sample() args (C910-native types), and bound the
// bins to C910-reachable state. Everything is guarded by MMU_COVERAGE:
// without +define+MMU_COVERAGE the covergroups compile out, leaving only the
// event type + a no-op collector. They are also compiled out under Verilator
// (no covergroup support) regardless of MMU_COVERAGE -- see the switch below.
//======================================================================
`ifndef MMU_COVERAGE_PKG_SV
`define MMU_COVERAGE_PKG_SV

// Covergroups are compiled in only when MMU_COVERAGE is defined AND the
// simulator supports them. Verilator does not implement SystemVerilog
// covergroups, so exclude them there even if MMU_COVERAGE is set -- otherwise a
// COV=1 build would fail to elaborate under Verilator. VERILATOR is predefined
// by verilator itself. The SV preprocessor has no `ifdef A && B`, hence the
// nested form deriving a single MMU_COVERAGE_ACTIVE switch.
`ifdef MMU_COVERAGE
  `ifndef VERILATOR
    `define MMU_COVERAGE_ACTIVE
  `endif
`endif

package mmu_coverage_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `include "mmu_cov_types.svh"
`ifdef MMU_COVERAGE_ACTIVE
  `include "mmu_paging_cov.svh"
  `include "mmu_cov_collector.svh"
`else
  // Coverage disabled: provide a no-op collector so the env can always
  // instantiate one without conditional compilation at the call site.
  class mmu_cov_collector extends uvm_subscriber #(mmu_xlate_result);
    `uvm_component_utils(mmu_cov_collector)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    virtual function void write(mmu_xlate_result t);
      // no-op when coverage is not compiled in
    endfunction
  endclass : mmu_cov_collector
`endif

endpackage : mmu_coverage_pkg

`endif // MMU_COVERAGE_PKG_SV