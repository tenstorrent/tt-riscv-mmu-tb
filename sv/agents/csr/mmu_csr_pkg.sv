// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_csr_pkg.sv
//
// Reusable VIP package for the CSR / CP0 agent (satp + T-Head regs, and
// the level priv/mstatus/enable pins). Bundles its item/driver/monitor/
// sequencer/agent into one namespace.
//
// The DUT interface (mmu_if) lives OUTSIDE any package; it is compiled
// before this package.
//======================================================================

`ifndef MMU_CSR_PKG_SV
`define MMU_CSR_PKG_SV

package mmu_csr_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `include "mmu_csr_seq_item.sv"
  `include "mmu_csr_driver.sv"
  `include "mmu_csr_monitor.sv"
  `include "mmu_csr_sequencer.sv"
  `include "mmu_csr_agent.sv"
  `include "mmu_csr_cfg_seq.sv"

endpackage : mmu_csr_pkg

`endif // MMU_CSR_PKG_SV
