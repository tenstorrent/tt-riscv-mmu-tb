// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_ifu_seq_item.sv
//
// Transaction for the IFU (instruction-fetch) translation agent.
//
//   request  (driven)   : {va, abort}          -> ifu_drv_cb
//   response (captured) : {pa, pavld, pgflt,    <- mmu_ifu_* outputs
//                          deny, ca, sec, bufferable}
//
// Included into mmu_pkg. Field widths mirror ct_mmu_top (ifu_mmu_va=63b,
// mmu_ifu_pa=28b). No per-agent config object.
//======================================================================
`ifndef MMU_IFU_SEQ_ITEM_SV
`define MMU_IFU_SEQ_ITEM_SV

class mmu_ifu_seq_item extends uvm_sequence_item;

  // ---- request (driven by mmu_ifu_driver) ----
  rand bit [62:0] va;          // ifu_mmu_va    (fetch virtual address)
  rand bit        abort;       // ifu_mmu_abort

  // Speculative request: model a front-end flow change. If the lookup misses
  // (walk in progress), the driver ABANDONS it via ifu_mmu_abort instead of
  // holding to completion — the RTL owes no response for an abandoned fetch.
  // A speculative request that HITS completes normally.
  rand bit        speculative;

  // ---- response bookkeeping (set by the driver) ----
  bit             abandoned;   // driver abandoned this (speculative) miss

  // Current privilege at the fetch cycle (captured by the monitor from
  // cp0_yy_priv_mode): 2'b00=U, 2'b01=S, 2'b11=M. Fetch uses the raw priv
  // (IUTLB ignores MPRV). M-mode bypasses translation (PA=VA, no fault).
  logic [1:0]     priv_mode;

  // C910 applies SUM to FETCH as well as load/store (C910 manual Ch.17 mstatus:
  // "load, store, and fetch requests"; ct_mmu_iutlb.v:599) -- a documented
  // deviation from RISC-V, which exempts fetch. Needed to score S-mode fetches
  // of U=1 pages. MXR is load-only, so the IFU does not capture it.
  logic           sum;         // cp0_mmu_sum

  // ---- response (captured from the DUT; 4-state to preserve X) ----
  logic [27:0] pa;             // mmu_ifu_pa    (physical page)
  logic        pavld;          // mmu_ifu_pavld
  logic        pgflt;          // mmu_ifu_pgflt (instruction page fault)
  logic        deny;           // mmu_ifu_deny  (PMP / exec-permission deny)
  logic        ca;             // mmu_ifu_ca    (cacheable)
  logic        sec;            // mmu_ifu_sec   (secure)
  logic        bufferable;     // mmu_ifu_buf   (`buf` is a reserved keyword)

  `uvm_object_utils_begin(mmu_ifu_seq_item)
    `uvm_field_int(va,          UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(abort,       UVM_ALL_ON)
    `uvm_field_int(speculative, UVM_ALL_ON)
    `uvm_field_int(abandoned,   UVM_ALL_ON)
    `uvm_field_int(pa,         UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(pavld,      UVM_ALL_ON)
    `uvm_field_int(pgflt,      UVM_ALL_ON)
    `uvm_field_int(deny,       UVM_ALL_ON)
    `uvm_field_int(ca,         UVM_ALL_ON)
    `uvm_field_int(sec,        UVM_ALL_ON)
    `uvm_field_int(bufferable, UVM_ALL_ON)
    `uvm_field_int(priv_mode,  UVM_ALL_ON)
    `uvm_field_int(sum,        UVM_ALL_ON)
  `uvm_object_utils_end

  // Aborts and speculative fetches are the exception, not the default.
  constraint c_abort_default       { soft abort       == 1'b0; }
  constraint c_speculative_default { soft speculative == 1'b0; }

  function new(string name = "mmu_ifu_seq_item");
    super.new(name);
  endfunction

  virtual function string convert2string();
    return $sformatf(
      "IFU va=0x%0h abort=%0b -> pavld=%0b pa=0x%0h pgflt=%0b deny=%0b ca=%0b sec=%0b buf=%0b",
      va, abort, pavld, pa, pgflt, deny, ca, sec, bufferable);
  endfunction

endclass : mmu_ifu_seq_item

`endif // MMU_IFU_SEQ_ITEM_SV
