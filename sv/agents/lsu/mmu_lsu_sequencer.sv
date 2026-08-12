// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_lsu_sequencer.sv
//
// Sequencer for LSU (data) translation transactions. Standard typed
// sequencer; the LSU stimulus sequence runs on it and its items are consumed
// by mmu_lsu_driver (which dispatches them across pipe0/pipe1).
//======================================================================
`ifndef MMU_LSU_SEQUENCER_SV
`define MMU_LSU_SEQUENCER_SV

typedef uvm_sequencer #(mmu_lsu_seq_item) mmu_lsu_sequencer;

`endif // MMU_LSU_SEQUENCER_SV
