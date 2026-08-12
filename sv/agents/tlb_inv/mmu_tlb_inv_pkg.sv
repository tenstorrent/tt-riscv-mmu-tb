// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_tlb_inv_pkg.sv  -- TLB-invalidation agent (sfence.vma driver/monitor).
//======================================================================
`ifndef MMU_TLB_INV_PKG_SV
`define MMU_TLB_INV_PKG_SV

package mmu_tlb_inv_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `include "mmu_tlb_inv_seq_item.sv"
  `include "mmu_tlb_inv_sequencer.sv"
  `include "mmu_tlb_inv_driver.sv"
  `include "mmu_tlb_inv_monitor.sv"
  `include "mmu_tlb_inv_agent.sv"
endpackage : mmu_tlb_inv_pkg

`endif // MMU_TLB_INV_PKG_SV
