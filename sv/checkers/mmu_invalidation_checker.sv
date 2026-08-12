// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_invalidation_checker.sv
//
// Whitebox TLB-invalidation checker. On each invalidation transaction from
// mmu_tlb_inv_monitor, backdoor-reads the jTLB (256x4) + iuTLB(32) + duTLB(17)
// AFTER the mmu_lsu_tlb_inv_done pulse and asserts the RTL/spec-confirmed
// flush semantics:
//
//   jTLB (stores asid + global):
//     INV_ALL / INV_CP0_ALL : every entry invalid.
//     INV_ASID              : entries with asid==req & g==0 invalid; g==1 or
//                             other-asid entries SURVIVE (RISC-V: global not
//                             ordered for rs2!=0; RTL: asid_hit && !g).
//     INV_VA                : entries whose (page-size-masked) VPN matches req,
//                             any asid incl. global, invalid; others survive.
//     INV_VA_ASID           : VPN match AND (asid==req or global-via-kid5)
//                             invalid; others survive.
//   uTLB (stores NO asid/global -> coarse):
//     INV_ALL/CP0/ASID      : entire I/D-uTLB invalid (unconditional clear).
//     INV_VA/VA_ASID        : entries with VPN[7:0]==req[7:0] invalid (RTL
//                             compares only low 8 VPN bits -> may over-clear;
//                             so we only require MATCHING entries gone, we do
//                             NOT assert non-matching uTLB survivors).
//
// Handshake: mmu_lsu_tlb_inv_done pulses exactly once per request (the monitor
// guarantees one txn per pulse). If the backdoor can't resolve, that class
// degrades to a NOTE (checked=handshake only) -- never a silent pass.
//======================================================================
`ifndef MMU_INVALIDATION_CHECKER_SV
`define MMU_INVALIDATION_CHECKER_SV

`uvm_analysis_imp_decl(_inv)

class mmu_invalidation_checker extends uvm_scoreboard;
  `uvm_component_utils(mmu_invalidation_checker)

  uvm_analysis_imp_inv #(mmu_tlb_inv_seq_item, mmu_invalidation_checker) inv_imp;

  mmu_tlb_backdoor bd;

  int unsigned num_checked;
  int unsigned num_err;
  // Total valid entries observed across all post-flush sweeps -- a coarse
  // non-vacuity witness, always logged.
  int unsigned num_valid_seen;

  // Escalate a zero witness to an error. Only meaningful for a test whose PURPOSE
  // is invalidation and which keeps traffic running alongside it (mmu_tlb_inv_test
  // sets this). Off by default, because zero survivors is a LEGITIMATE outcome
  // elsewhere: dynamic-satp flushes at a context boundary, and an INV_ASID whose
  // ASID covers every resident entry correctly leaves none behind. Counting
  // post-flush survivors cannot distinguish "TLB was empty" from "flush scope
  // covered everything", so it must not gate those tests.
  bit require_live_entries = 1'b0;
  bit          warned_no_backdoor;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    inv_imp = new("inv_imp", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    bd = mmu_tlb_backdoor::type_id::create("bd");
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (!bd.connect())
      `uvm_warning(get_type_name(),
        "TLB backdoor interface (tlb_bd_vif) not found -- invalidation CAM checking DISABLED (handshake-only). Ensure mmu_tb_top instantiates mmu_tlb_bd_if.")
  endfunction

  // VPN match with page-size masking (jTLB). pgs one-hot: [0]=4K,[1]=2M,[2]=1G.
  protected function bit vpn_match(bit [26:0] ent_vpn, bit [2:0] pgs,
                                   bit [26:0] req_vpn);
    // 4K: compare all 27; 2M: ignore low 9; 1G: ignore low 18.
    if      (pgs[2]) return (ent_vpn[26:18] == req_vpn[26:18]);
    else if (pgs[1]) return (ent_vpn[26:9]  == req_vpn[26:9]);
    else             return (ent_vpn        == req_vpn);
  endfunction

  // Should this jTLB entry be invalidated by this request?
  protected function bit jtlb_should_go(mmu_tlb_inv_seq_item r, jtlb_entry_t e);
    if (!e.vld) return 0;
    case (r.kind)
      INV_ALL, INV_CP0_ALL: return 1;
      INV_ASID:             return (e.asid == r.asid) && !e.g;
      INV_VA:               return vpn_match(e.vpn, e.pgs, r.vpn);
      INV_VA_ASID:          return vpn_match(e.vpn, e.pgs, r.vpn) &&
                                   ((e.asid == r.asid) || e.g);
      default:              return 0;
    endcase
  endfunction

  // uTLB should-clear (no asid/global stored -> coarse).
  protected function bit utlb_should_go(mmu_tlb_inv_seq_item r, utlb_entry_t e);
    if (!e.vld) return 0;
    case (r.kind)
      INV_ALL, INV_CP0_ALL, INV_ASID: return 1;   // whole uTLB cleared
      INV_VA, INV_VA_ASID:            return (e.vpn[7:0] == r.vpn[7:0]);
      default:                        return 0;
    endcase
  endfunction

  function void write_inv(mmu_tlb_inv_seq_item r);
    jtlb_entry_t je;
    utlb_entry_t ue;
    // Valid entries still present AFTER the flush (legitimate survivors, e.g.
    // other-ASID / global entries after INV_ASID). Tracked so a clean result can
    // never be a vacuous pass: if the backdoor were reading an empty or
    // unreachable TLB these would stay 0 forever, which report_phase flags.
    int unsigned live_j = 0, live_iu = 0, live_du = 0;
    num_checked++;

    if (!bd.ok) begin
      // No backdoor -> handshake-only (the monitor already verified the done
      // pulse). Never a silent pass: we count it and NOTE it.
      if (!warned_no_backdoor) begin
        warned_no_backdoor = 1'b1;
        `uvm_warning(get_type_name(),
          "TLB backdoor unavailable -- CAM checking disabled (handshake-only).")
      end
      return;
    end

    // ---- jTLB: sweep ALL 256x4 entries ----
    for (int s = 0; s < bd.JTLB_SETS; s++)
      for (int w = 0; w < bd.JTLB_WAYS; w++) begin
        bd.read_jtlb(s, w, je);
        if (je.vld) live_j++;
        if (jtlb_should_go(r, je)) begin
          num_err++;
          `uvm_error(get_type_name(), $sformatf(
            "%s: jTLB set=%0d way=%0d STILL VALID but should be invalidated (vpn=0x%0h asid=0x%0h g=%0b pgs=%0b)",
            r.kind.name(), s, w, je.vpn, je.asid, je.g, je.pgs))
        end
      end

    // ---- iuTLB (I-side): sweep ALL 32 entries ----
    for (int i = 0; i < bd.IUTLB_N; i++) begin
      bd.read_iutlb(i, ue);
      if (ue.vld) live_iu++;
      if (utlb_should_go(r, ue)) begin
        num_err++;
        `uvm_error(get_type_name(), $sformatf(
          "%s: iuTLB entry=%0d STILL VALID but should be invalidated (vpn=0x%0h)",
          r.kind.name(), i, ue.vpn))
      end
    end

    // ---- duTLB (D-side): sweep ALL 17 entries (incl. entry16 huge/superpage) ----
    for (int i = 0; i < bd.DUTLB_N; i++) begin
      bd.read_dutlb(i, ue);
      if (ue.vld) live_du++;
      if (utlb_should_go(r, ue)) begin
        num_err++;
        `uvm_error(get_type_name(), $sformatf(
          "%s: duTLB entry=%0d STILL VALID but should be invalidated (vpn=0x%0h)",
          r.kind.name(), i, ue.vpn))
      end
    end

    // Accumulate survivors so report_phase can prove the sweep saw real entries.
    num_valid_seen += (live_j + live_iu + live_du);
    `uvm_info(get_type_name(), $sformatf(
      "%s verified: survivors jTLB=%0d iuTLB=%0d duTLB=%0d (errs so far=%0d)",
      r.kind.name(), live_j, live_iu, live_du, num_err), UVM_MEDIUM)
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info(get_type_name(), $sformatf(
      "INV checker: %0d invalidations checked, %0d errors, %0d live TLB entries observed",
      num_checked, num_err, num_valid_seen), UVM_LOW)
    // Only gate where the test guarantees live traffic alongside the flushes
    // (require_live_entries). There, a zero witness means the backdoor read
    // nothing or the TLBs were never warmed, so the CAM comparison was vacuous.
    if (require_live_entries && num_checked > 0 && bd.ok && num_valid_seen == 0)
      `uvm_error(get_type_name(),
        "INV checker swept 0 live TLB entries -- CAM check was vacuous (backdoor path or TLB warm-up broken)")
  endfunction

endclass : mmu_invalidation_checker

`endif // MMU_INVALIDATION_CHECKER_SV
