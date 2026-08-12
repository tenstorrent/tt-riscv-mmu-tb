// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_test_pkg.sv
//
// Test package: holds all uvm_test classes. Tests build on the env, so
// this imports mmu_env_pkg (and transitively the agent VIPs). Adding a
// new test never touches the env or agents.
//
//   mmu_test_pkg -> mmu_env_pkg -> {mmu_ifu_pkg, mmu_csr_pkg}
//
// mmu_tb_top only needs `import mmu_test_pkg::*` and gets the whole
// hierarchy transitively.
//======================================================================

`ifndef MMU_TEST_PKG_SV
`define MMU_TEST_PKG_SV

package mmu_test_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import mmu_env_pkg::*;
  import mmu_ifu_pkg::*;
  import mmu_lsu_pkg::*;
  import mmu_csr_pkg::*;

  import mmu_ptwmem_pkg::*;
  // mmu_pmp_config is declared in mmu_pmp_pkg (not mmu_env_pkg) -- import it
  // directly here (a wildcard import doesn't chain through a second package hop).
  import mmu_pmp_pkg::*;

  `include "mmu_base_test.sv"
  `include "mmu_ifu_test.sv"
  `include "mmu_lsu_test.sv"
  `include "mmu_ifu_lsu_test.sv"
  `include "mmu_tlb_inv_test.sv"
  `include "mmu_csr_reg_test.sv"
  `include "mmu_dynamic_satp_test.sv"
  // DUT-free harness for the page-table config generator.
  `include "mmu_ptcfg_gen_test.sv"
  // PMP is now common stimulus applied in mmu_base_seq (every test exercises a
  // randomized PMP config), so the standalone mmu_pmp_smoke_test / mmu_pmp_cfg_test
  // are retired.


endpackage : mmu_test_pkg

`endif // MMU_TEST_PKG_SV
