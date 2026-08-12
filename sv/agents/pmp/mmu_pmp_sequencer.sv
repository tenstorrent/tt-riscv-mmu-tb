// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_pmp_sequencer.sv
//
// Sequencer for the PMP config-manager agent. Single sequencer -- one
// config bus: applying a config is a single instantaneous write from the
// driver's point of view, matching the agent's single-sqr shape (mirrors
// mmu_ifu_sequencer).
//======================================================================
`ifndef MMU_PMP_SEQUENCER_SV
`define MMU_PMP_SEQUENCER_SV

typedef uvm_sequencer #(mmu_pmp_seq_item) mmu_pmp_sequencer;

`endif // MMU_PMP_SEQUENCER_SV
