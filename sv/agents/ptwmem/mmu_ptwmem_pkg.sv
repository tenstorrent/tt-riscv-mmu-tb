// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_ptwmem_pkg.sv
//
// Reusable VIP package for the PTW memory-bus agent (responder that serves
// page-table reads from the shared mmu_sysmem). Imports mmu_common_pkg
// for the memory model type.
//
// The DUT interface (mmu_if) is compiled outside any package.
//======================================================================

`ifndef MMU_PTWMEM_PKG_SV
`define MMU_PTWMEM_PKG_SV

package mmu_ptwmem_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import mmu_common_pkg::*;

  `include "mmu_ptwmem_responder.sv"
  `include "mmu_ptwmem_agent.sv"

endpackage : mmu_ptwmem_pkg

`endif // MMU_PTWMEM_PKG_SV
