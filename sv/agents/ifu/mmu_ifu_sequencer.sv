// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_ifu_sequencer.sv
//
// Sequencer for IFU translation transactions. Standard typed sequencer;
// sequences (fetch stimulus) run on it and its items are consumed by
// mmu_ifu_driver.
//======================================================================
`ifndef MMU_IFU_SEQUENCER_SV
`define MMU_IFU_SEQUENCER_SV

typedef uvm_sequencer #(mmu_ifu_seq_item) mmu_ifu_sequencer;

`endif // MMU_IFU_SEQUENCER_SV
