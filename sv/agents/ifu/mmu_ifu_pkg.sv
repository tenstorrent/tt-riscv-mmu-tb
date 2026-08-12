// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_ifu_pkg.sv
//
// Reusable VIP package for the IFU (instruction-fetch) translation agent.
// Bundles the agent's item/driver/monitor/sequencer/agent into one
// namespace so it compiles once and can be imported by the env.
//
// The DUT interface (mmu_if) lives OUTSIDE any package (virtual interfaces
// cannot be declared in a package); it is compiled before this package.
//======================================================================

`ifndef MMU_IFU_PKG_SV
`define MMU_IFU_PKG_SV

package mmu_ifu_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import mmu_common_pkg::*;   // mmu_va_map_t (golden map for the translate seq)

  `include "mmu_ifu_seq_item.sv"
  `include "mmu_ifu_driver.sv"
  `include "mmu_ifu_monitor.sv"
  `include "mmu_ifu_sequencer.sv"
  `include "mmu_ifu_agent.sv"
  `include "mmu_ifu_translate_seq.sv"

endpackage : mmu_ifu_pkg

`endif // MMU_IFU_PKG_SV
