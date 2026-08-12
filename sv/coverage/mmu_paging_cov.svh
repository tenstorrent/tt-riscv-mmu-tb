// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_paging_cov.svh
//
// C910 single-stage (Sv39) paging functional coverage. Explicit-sample()
// rewrite of the corearchcoverage paging covergroup content: the
// coverpoint/bin intent is ported, but inputs are typed sample() args
// bound to the C910 testbench's resolved-translation event, and bins are
// bounded to C910-reachable state (Sv39/Bare, U/S/M, page vs access fault,
// leaf PTE attribute bits).
//
// Included inside mmu_coverage_pkg.
//======================================================================
`ifndef MMU_PAGING_COV_SVH
`define MMU_PAGING_COV_SVH

  // Wrapped in a class so the covergroup can be instantiated per-collector
  // and sampled by method call.
  class mmu_paging_cov extends uvm_object;
    `uvm_object_utils(mmu_paging_cov)

    // Sampled inputs (members so the embedded covergroup sees them).
    mmu_cov_mode_e  s_mode;
    mmu_cov_priv_e  s_priv;
    mmu_cov_acc_e   s_acc;
    mmu_cov_fault_e s_fault;
    bit             s_leaf_valid;
    bit             s_pte_r, s_pte_w, s_pte_x, s_pte_u, s_pte_g, s_pte_a, s_pte_d;

    covergroup paging_cg;
      option.per_instance = 1;
      option.name         = "mmu_paging_cg";

      cp_mode : coverpoint s_mode;

      cp_priv : coverpoint s_priv {
        ignore_bins rsvd = {MMU_COV_PRIV_RSVD};
      }

      cp_acc : coverpoint s_acc;

      cp_fault : coverpoint s_fault;

      // Leaf PTE permission/attribute bits (only meaningful on a paged walk).
      cp_pte_r : coverpoint s_pte_r iff (s_leaf_valid);
      cp_pte_w : coverpoint s_pte_w iff (s_leaf_valid);
      cp_pte_x : coverpoint s_pte_x iff (s_leaf_valid);
      cp_pte_u : coverpoint s_pte_u iff (s_leaf_valid);
      cp_pte_g : coverpoint s_pte_g iff (s_leaf_valid);
      cp_pte_a : coverpoint s_pte_a iff (s_leaf_valid);
      cp_pte_d : coverpoint s_pte_d iff (s_leaf_valid);

      // Leaf permission combination (R/W/X) -- excludes W-only (illegal encoding).
      cp_pte_rwx : coverpoint {s_pte_r, s_pte_w, s_pte_x} iff (s_leaf_valid) {
        bins pointer    = {3'b000};
        bins ro         = {3'b100};
        bins rw         = {3'b110};
        bins rx         = {3'b101};
        bins rwx        = {3'b111};
        bins xo         = {3'b001};
        illegal_bins wo = {3'b010, 3'b011};  // W without R is reserved
      }

      // Which access kind hit which fault -- the core paging-permission matrix.
      cr_acc_x_fault : cross cp_acc, cp_fault;

      // Fault kind per privilege (U vs S paging behavior).
      cr_priv_x_fault : cross cp_priv, cp_fault;

      // U-bit vs the privilege that touched the page (SUM/U-access semantics).
      cr_priv_x_ubit : cross cp_priv, cp_pte_u iff (s_leaf_valid);
    endgroup

    function new(string name = "mmu_paging_cov");
      super.new(name);
      paging_cg = new();
    endfunction

    // Sample one resolved translation.
    function void sample(mmu_xlate_result r);
      s_mode       = r.mode;
      s_priv       = r.priv;
      s_acc        = r.acc;
      s_fault      = r.fault;
      s_leaf_valid = r.leaf_valid;
      // RISC-V PTE bit layout: [0]=V [1]=R [2]=W [3]=X [4]=U [5]=G [6]=A [7]=D
      s_pte_r = r.leaf_pte[1];
      s_pte_w = r.leaf_pte[2];
      s_pte_x = r.leaf_pte[3];
      s_pte_u = r.leaf_pte[4];
      s_pte_g = r.leaf_pte[5];
      s_pte_a = r.leaf_pte[6];
      s_pte_d = r.leaf_pte[7];
      paging_cg.sample();
    endfunction
  endclass : mmu_paging_cov

`endif // MMU_PAGING_COV_SVH