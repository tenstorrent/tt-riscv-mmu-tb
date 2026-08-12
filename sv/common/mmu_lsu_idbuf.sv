// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_lsu_idbuf.sv
//
// Outstanding-id model for the LSU data agent (the C910 LSQ/LSIQ stand-in;
// models the LS miss-buffer queue). Vends a bounded pool of 7-bit
// request ids (lsu_mmu_idN) and tracks which are in flight so the driver can
// allocate an id per access and free it on completion, and (later) so the
// sequence can back-pressure when the queue is full.
//
// Pool size = 12, matching the mmu_lsu_tlb_wakeup[11:0] width. First-cut the
// driver keeps <=1 outstanding per pipe, so this is only lightly exercised.
//======================================================================
`ifndef MMU_LSU_IDBUF_SV
`define MMU_LSU_IDBUF_SV

class mmu_lsu_idbuf extends uvm_object;
  `uvm_object_utils(mmu_lsu_idbuf)

  localparam int unsigned NUM_IDS = 12;   // matches mmu_lsu_tlb_wakeup width

  local bit busy[NUM_IDS];

  function new(string name = "mmu_lsu_idbuf");
    super.new(name);
  endfunction

  // Allocate a free id, or -1 if the pool is full.
  function int alloc();
    for (int i = 0; i < NUM_IDS; i++)
      if (!busy[i]) begin busy[i] = 1'b1; return i; end
    return -1;
  endfunction

  function void free(int id);
    if (id >= 0 && id < NUM_IDS) busy[id] = 1'b0;
  endfunction

  function bit is_full();
    for (int i = 0; i < NUM_IDS; i++) if (!busy[i]) return 1'b0;
    return 1'b1;
  endfunction

endclass : mmu_lsu_idbuf

`endif // MMU_LSU_IDBUF_SV
