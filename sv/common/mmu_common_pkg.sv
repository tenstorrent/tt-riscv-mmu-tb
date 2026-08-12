// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_common_pkg.sv
//
// Shared, DUT-agnostic building blocks used by multiple higher-level
// packages (env, agents). Kept at the bottom of the dependency chain so
// both the ptw_mem agent and the env can import it without a cycle.
//
//   {mmu_ptwmem_pkg, mmu_env_pkg}  ->  mmu_common_pkg
//
// Currently: the sparse physical-memory model.
//======================================================================

`ifndef MMU_COMMON_PKG_SV
`define MMU_COMMON_PKG_SV

package mmu_common_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // Golden VA->PA/size map entry (kept here now that the flat-file loader is gone;
  // still used by mmu_ifu_translate_seq as the per-page self-check golden).
  typedef struct {
    longint unsigned va;
    longint unsigned pa;
    int    unsigned  page_kb;
  } mmu_va_map_t;

  // Corrupt a canonical Sv39 VA into a guaranteed non-canonical one (breaks the
  // VA[63:39] sign-extension of VA[38]) -> IUTLB illegal-VA page fault. 10% polar
  // complement, 90% random with the MSB forced if it lands canonical.
  function automatic bit [63:0] mmu_bad_va_sv39(bit [63:0] va);
    bit [63:0] bad = va;
    if ($urandom_range(0, 9) == 0)                        // 10% polar complement
      bad[63:39] = va[38] ? 25'b0 : {25{1'b1}};           // upper = opposite of sign bit
    else begin                                            // 90% random upper bits
      bad[63:39] = $urandom();
      if (bad[63:39] == {25{va[38]}}) bad[63] = ~va[38];  // rare canonical hit -> force illegal
    end
    return bad;
  endfunction

  // DUT/TB physical memory (sysmem + mem-manager DPI). sysmem/mem_manager
  // packages are compiled before this package (see filelist.f).
  `include "mmu_sysmem.sv"

  // LSU outstanding-id (LSQ/LSIQ) model, shared by the LSU agent + stimulus.
  `include "mmu_lsu_idbuf.sv"

endpackage : mmu_common_pkg

`endif // MMU_COMMON_PKG_SV
