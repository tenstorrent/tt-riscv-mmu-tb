// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_cov_types.svh
//
// C910-native coverage types for the MMU functional coverage collector.
// These are the explicit-sample() inputs (the "cleaner" strategy): the
// scoreboard emits an mmu_xlate_result per resolved translation and the
// collector samples covergroups from typed fields -- no reproduced arch
// model globals.
//
// Included inside mmu_coverage_pkg.
//======================================================================
`ifndef MMU_COV_TYPES_SVH
`define MMU_COV_TYPES_SVH

  // Privilege the (effective) access ran at.
  typedef enum bit [1:0] {
    MMU_COV_PRIV_U = 2'b00,
    MMU_COV_PRIV_S = 2'b01,
    MMU_COV_PRIV_RSVD = 2'b10,
    MMU_COV_PRIV_M = 2'b11
  } mmu_cov_priv_e;

  // Access kind of the request.
  typedef enum bit [1:0] {
    MMU_COV_ACC_FETCH = 2'd0,
    MMU_COV_ACC_LOAD  = 2'd1,
    MMU_COV_ACC_STORE = 2'd2
  } mmu_cov_acc_e;

  // Translation mode active for the access.
  typedef enum bit [1:0] {
    MMU_COV_MODE_MBYPASS = 2'd0,  // M-mode bypass (no walk)
    MMU_COV_MODE_BARE    = 2'd1,  // satp.MODE == Bare
    MMU_COV_MODE_SV39    = 2'd2   // satp.MODE == Sv39 (only paged mode on C910)
  } mmu_cov_mode_e;

  // Resolved fault classification (C910-produceable set).
  typedef enum bit [1:0] {
    MMU_COV_FLT_NONE   = 2'd0,
    MMU_COV_FLT_PAGE   = 2'd1,
    MMU_COV_FLT_ACCESS = 2'd2
  } mmu_cov_fault_e;

  // Resolved-translation event emitted by the scoreboard, consumed by the
  // coverage collector. Carries stimulus + reference prediction (not the
  // DUT-vs-ref verdict -- coverage scores what was exercised).
  class mmu_xlate_result extends uvm_sequence_item;
    bit [63:0]      va;
    mmu_cov_priv_e  priv;
    mmu_cov_acc_e   acc;
    mmu_cov_mode_e  mode;
    mmu_cov_fault_e fault;
    bit [63:0]      leaf_pte;     // Whisper leaf PTE (valid when a walk ran)
    bit             leaf_valid;   // 1 when leaf_pte is meaningful (paged walk)

    `uvm_object_utils(mmu_xlate_result)

    function new(string name = "mmu_xlate_result");
      super.new(name);
    endfunction
  endclass : mmu_xlate_result

`endif // MMU_COV_TYPES_SVH