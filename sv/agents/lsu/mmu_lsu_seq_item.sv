// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_lsu_seq_item.sv
//
// Transaction for the LSU (data load/store) translation agent.
//
//   request  (driven)   : {va, st_inst}         -> lsu_drv_cb (pipe0/1)
//   response (captured) : {pa, pa_vld,           <- mmu_lsu_* outputs
//                          page_fault, access_fault, ca, sec, sh, so, buf}
//
// The full 64-bit byte VA is driven (NOT shifted, unlike IFU); the duTLB reads
// vpn = va[38:12]. st_inst selects load (0) vs store (1). The driver fills
// {pipe, id}; the monitor fills the response fields on its emitted txn.
//======================================================================
`ifndef MMU_LSU_SEQ_ITEM_SV
`define MMU_LSU_SEQ_ITEM_SV

class mmu_lsu_seq_item extends uvm_sequence_item;

  // ---- request (driven by mmu_lsu_driver) ----
  rand bit [63:0] va;          // lsu_mmu_vaN     (full byte virtual address)
  rand bit        st_inst;     // lsu_mmu_st_instN (0=load, 1=store)

  // ---- pipe / id ----
  // pipe: which fast pipe this txn belongs to (0/1). Set by the driver on
  // driven items AND by the monitor on captured items (capture_pipeN). It is
  // LOAD-BEARING for the scoreboard's PMP predictor, not just bookkeeping:
  // pipe0 hardwires dutlb_ori_read=1 so it PMP-checks R on every access incl.
  // a store (ct_mmu_dutlb.v:1370), so pmp_deny() keys its always-R term on
  // (tr.pipe==0). Keep the monitor's pipeN assignment exact.
  bit [1:0]  pipe;
  bit [6:0]  id;               // lsu_mmu_idN allocated from mmu_lsu_idbuf

  // ---- privilege context (captured by the monitor at the response cycle) ----
  // Data accesses honor MPRV: the EFFECTIVE priv used for translation + PMP is
  // (mprv ? mpp : priv_mode) -- unlike the IFU, which ignores MPRV. M-mode data
  // with mprv=0 bypasses translation; mprv=1 & mpp=S makes M-mode actually walk
  // (the M-mode-walk PMP path). The scoreboard derives the effective priv.
  logic [1:0] priv_mode;       // cp0_yy_priv_mode
  logic       mprv;            // cp0_mmu_mprv
  logic [1:0] mpp;             // cp0_mmu_mpp
  logic       sum;             // cp0_mmu_sum (S-mode access to U=1 leaf; data only)
  logic       mxr;             // cp0_mmu_mxr (read of X-only leaf; data only)

  // ---- response (captured from the DUT; 4-state to preserve X) ----
  logic [27:0] pa;             // mmu_lsu_paN
  logic        pa_vld;         // mmu_lsu_paN_vld
  logic        page_fault;     // mmu_lsu_page_faultN
  logic        access_fault;   // mmu_lsu_access_faultN
  logic        ca;             // mmu_lsu_caN   (cacheable)
  logic        sec;            // mmu_lsu_secN  (secure)
  logic        sh;             // mmu_lsu_shN   (shareable)
  logic        so;             // mmu_lsu_soN   (strong-order)
  logic        bufferable;     // mmu_lsu_bufN  (`buf` is a reserved keyword)

  `uvm_object_utils_begin(mmu_lsu_seq_item)
    `uvm_field_int(va,           UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(st_inst,      UVM_ALL_ON)
    `uvm_field_int(pipe,         UVM_ALL_ON)
    `uvm_field_int(id,           UVM_ALL_ON)
    `uvm_field_int(priv_mode,    UVM_ALL_ON)
    `uvm_field_int(mprv,         UVM_ALL_ON)
    `uvm_field_int(mpp,          UVM_ALL_ON)
    `uvm_field_int(sum,          UVM_ALL_ON)
    `uvm_field_int(mxr,          UVM_ALL_ON)
    `uvm_field_int(pa,           UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(pa_vld,       UVM_ALL_ON)
    `uvm_field_int(page_fault,   UVM_ALL_ON)
    `uvm_field_int(access_fault, UVM_ALL_ON)
    `uvm_field_int(ca,           UVM_ALL_ON)
    `uvm_field_int(sec,          UVM_ALL_ON)
    `uvm_field_int(sh,           UVM_ALL_ON)
    `uvm_field_int(so,           UVM_ALL_ON)
    `uvm_field_int(bufferable,   UVM_ALL_ON)
  `uvm_object_utils_end

  // Loads are the default; stores are opt-in via the stimulus profile.
  constraint c_load_default { soft st_inst == 1'b0; }

  function new(string name = "mmu_lsu_seq_item");
    super.new(name);
  endfunction

  virtual function string convert2string();
    return $sformatf(
      "LSU pipe%0d %s va=0x%0h -> pa_vld=%0b pa=0x%0h pgflt=%0b accflt=%0b ca=%0b sec=%0b sh=%0b so=%0b buf=%0b",
      pipe, st_inst ? "ST" : "LD", va, pa_vld, pa, page_fault, access_fault, ca, sec, sh, so, bufferable);
  endfunction

endclass : mmu_lsu_seq_item

`endif // MMU_LSU_SEQ_ITEM_SV
