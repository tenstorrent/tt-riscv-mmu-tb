// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_checkers_pkg.sv
//
// Reference-model / scoreboard package. Imported by mmu_env_pkg.
//
// The C++ side (whisper_dv_mmu_dpi.{cpp,h} + libdvmmu.a) is compiled and
// linked into simv by the Makefile; this package only holds the SV wrapper's
// DPI import declarations + the UVM components.
//======================================================================

`ifndef MMU_CHECKERS_PKG_SV
`define MMU_CHECKERS_PKG_SV

package mmu_checkers_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // IFU + LSU transactions the scoreboard reconciles against Whisper.
  import mmu_ifu_pkg::*;
  import mmu_lsu_pkg::*;
  // mmu_pmp_config: the scoreboard subscribes to the PMP agent's monitor.
  // Imported directly because a wildcard import does not chain through a
  // second package hop.
  import mmu_pmp_pkg::*;
  // mmu_sysmem: the scoreboard's SV page-table walker reads PTEs from the
  // shared physical memory to score per-PTE-read PMP (walk_pmp_deny).
  import mmu_common_pkg::*;
  // TLB-invalidation transactions (mmu_tlb_inv_seq_item) that the invalidation
  // checker consumes from the tlb_inv agent's monitor.
  import mmu_tlb_inv_pkg::*;
  // Functional-coverage event type (mmu_xlate_result). The scoreboard emits
  // one resolved-translation event per check on its xlate_ap; the coverage
  // collector (built in the env) samples covergroups from it.
  import mmu_coverage_pkg::*;

  // Whisper DvMmu reference-model DPI wrapper (DPI imports + whisper_dv_mmu class).
  `include "whisper_dv_mmu.sv"
  // DUT-vs-Whisper scoreboard.
  // C910 PMA/PMP fault predictor, then the generic scoreboard base, then the
  // C910 scoreboard that extends it. Order matters: each depends on the prior.
  `include "mmu_c910_pma_pmp.sv"
  `include "mmu_scoreboard_base.sv"
  `include "mmu_scoreboard.sv"
  // Whitebox TLB backdoor reader + invalidation checker.
  `include "mmu_tlb_backdoor.sv"
  `include "mmu_invalidation_checker.sv"

endpackage : mmu_checkers_pkg

`endif // MMU_CHECKERS_PKG_SV
