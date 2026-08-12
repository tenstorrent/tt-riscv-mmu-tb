// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_pmp_pkg.sv
//
// Reusable VIP package for the PMP config-manager agent. Bundles the
// 16-entry PMP config model (mmu_pmp_config, formerly included directly by
// mmu_env_pkg) with the agent that writes it into the interface
// (mmu_if.pmp_cfg -- read by the interface's combinational responder) and
// broadcasts each applied config toward the scoreboard.
//
// mmu_pmp_config is declared HERE (not mmu_common_pkg) so downstream
// packages (mmu_env_pkg, mmu_test_pkg, and mmu_checkers_pkg once the
// scoreboard subscribes) can reach it with a single direct
// `import mmu_pmp_pkg::*`, mirroring how mmu_ifu_pkg/mmu_lsu_pkg's
// seq_item types are consumed elsewhere in this dependency chain (see
// those packages' redundant direct imports into mmu_checkers_pkg/
// mmu_test_pkg for the same reason -- SV wildcard imports do not chain
// through a second package hop).
//
// The DUT interface (mmu_if) lives OUTSIDE any package and is compiled first.
//======================================================================
`ifndef MMU_PMP_PKG_SV
`define MMU_PMP_PKG_SV

package mmu_pmp_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // 16-entry PMP region model: config + derived [lo,hi) bounds + matcher.
  `include "mmu_pmp_config.sv"

  `include "mmu_pmp_seq_item.sv"
  `include "mmu_pmp_driver.sv"
  `include "mmu_pmp_monitor.sv"
  `include "mmu_pmp_sequencer.sv"
  `include "mmu_pmp_agent.sv"

endpackage : mmu_pmp_pkg

`endif // MMU_PMP_PKG_SV
