// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_pmp_seq.sv
//
// Shared PMP-agent sequences.
//   - mmu_pmp_apply_seq : applies a mmu_pmp_config to the DUT.
//
// Included from mmu_env_pkg (after mmu_pmp_pkg's mmu_pmp_seq_item and
// mmu_csr_pkg's mmu_csr_seq_item are both already visible), so any test
// package that imports mmu_env_pkg::* gets one shared definition.
//======================================================================

`ifndef MMU_PMP_SEQ_SV
`define MMU_PMP_SEQ_SV

// Wraps one full mmu_pmp_config into a single mmu_pmp_seq_item and pushes it
// through the PMP config-manager sequencer -> driver -> vif.pmp_cfg -> monitor
// -> mmu_scoreboard::write_pmp() (which programs Whisper's PMP shadow regs).
class mmu_pmp_apply_seq extends uvm_sequence #(mmu_pmp_seq_item);
  `uvm_object_utils(mmu_pmp_apply_seq)

  mmu_pmp_config cfg;

  function new(string name = "mmu_pmp_apply_seq");
    super.new(name);
  endfunction

  task body();
    req = mmu_pmp_seq_item::type_id::create("req");
    start_item(req);
    req.cfg = cfg;
    finish_item(req);
  endtask

endclass : mmu_pmp_apply_seq


`endif // MMU_PMP_SEQ_SV
