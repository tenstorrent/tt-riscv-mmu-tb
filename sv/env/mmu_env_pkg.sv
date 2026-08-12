// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_env_pkg.sv
//
// DUT-specific, test-independent environment package. It imports the
// reusable agent VIP packages and (as we build them) holds the env class,
// env config, virtual sequencer, scoreboard, mem_model and ptgen loader.
//
// Dependency chain:
//   mmu_test_pkg -> mmu_env_pkg -> {mmu_ifu_pkg, mmu_csr_pkg}
//
// The DUT interface (mmu_if) is compiled outside any package.
//======================================================================

`ifndef MMU_ENV_PKG_SV
`define MMU_ENV_PKG_SV

package mmu_env_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // Shared building blocks and reusable agent VIPs used by this environment.
  import mmu_common_pkg::*;
  import mmu_ifu_pkg::*;
  import mmu_lsu_pkg::*;
  import mmu_csr_pkg::*;
  import mmu_ptwmem_pkg::*;
  // PMP config-manager agent + the 16-entry PMP config model it
  // declares (mmu_pmp_config -- formerly `included directly below).
  import mmu_pmp_pkg::*;
  import mmu_tlb_inv_pkg::*;
  // Whisper DvMmu reference-model wrapper (+ scoreboard, added next).
  import mmu_checkers_pkg::*;
  // MMU functional-coverage collector + resolved-translation event type.
  import mmu_coverage_pkg::*;
  // Generated pysv DPI binding for the in-sim riescue page-table generator.
  import PageTableSV_pkg::*;

  // Virtual sequencer (used by mmu_env), the env class, then the in-sim
  // page-table base sequence (a virtual sequence on mmu_virtual_sequencer).
  `include "mmu_virtual_sequencer.sv"
  `include "mmu_env.sv"
  // Two independent page-table config generators, by design:
  //   _base -- DUT-agnostic (Sv39/48/57, two-stage, full fault set). Reusable
  //            for other DUTs; exercised only by mmu_ptcfg_gen_test.
  //   (below) the C910 generator that drives every test here.
  // Not parent/child: C910 needs leaf-only A/D/U (per-level trips the reference
  // model on non-leaf reserved bits), so it would override most of the base.
  `include "mmu_pt_config_gen_base.sv"
  `include "mmu_pt_config_gen.sv"
  // PMP config-apply + priv-set helper sequences. Included BEFORE mmu_base_seq
  // because the base flow (program_pmp) now applies a randomized PMP config as
  // common setup for every test, so it references mmu_pmp_apply_seq.
  `include "mmu_pmp_seq.sv"
  `include "mmu_base_seq.sv"
  // Per-unit stimulus sequences (extend mmu_base_seq, override drive_stimulus).
  `include "mmu_ifu_seq.sv"
  `include "mmu_lsu_seq.sv"
  `include "mmu_ifu_lsu_seq.sv"
  `include "mmu_tlb_inv_seq.sv"
  `include "mmu_csr_reg_seq.sv"
  // Mid-run PMP reprogramming sequence (+PMP_DYNAMIC variant).
  `include "mmu_pmp_update_seq.sv"
  `include "mmu_dynamic_satp_seq.sv"

endpackage : mmu_env_pkg

`endif // MMU_ENV_PKG_SV
