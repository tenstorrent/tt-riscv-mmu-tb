// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_csr_sequencer.sv
//
// Sequencer for CSR/CP0 transactions. Standard typed sequencer; the config
// sequence (CTX_SET priv=S + SATP_WRITE) runs on it, consumed by mmu_csr_driver.
//======================================================================
`ifndef MMU_CSR_SEQUENCER_SV
`define MMU_CSR_SEQUENCER_SV

typedef uvm_sequencer #(mmu_csr_seq_item) mmu_csr_sequencer;

`endif // MMU_CSR_SEQUENCER_SV
