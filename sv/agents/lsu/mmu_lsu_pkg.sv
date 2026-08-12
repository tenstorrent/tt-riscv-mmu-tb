// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_lsu_pkg.sv
//
// Reusable VIP package for the LSU (data load/store) translation agent.
// Bundles the agent's item/driver/monitor/sequencer/agent into one namespace.
//
// The DUT interface (mmu_if) lives OUTSIDE any package and is compiled first.
// mmu_common_pkg (imported here) provides mmu_lsu_idbuf and mmu_va_map_t.
//======================================================================
`ifndef MMU_LSU_PKG_SV
`define MMU_LSU_PKG_SV

package mmu_lsu_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import mmu_common_pkg::*;   // mmu_lsu_idbuf, mmu_va_map_t

  `include "mmu_lsu_seq_item.sv"
  `include "mmu_lsu_driver.sv"
  `include "mmu_lsu_monitor.sv"
  `include "mmu_lsu_sequencer.sv"
  `include "mmu_lsu_agent.sv"
  `include "mmu_lsu_translate_seq.sv"

endpackage : mmu_lsu_pkg

`endif // MMU_LSU_PKG_SV
