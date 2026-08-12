// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_scoreboard.sv
//
// DUT-vs-Whisper scoreboard for the C910 MMU -- EXTENDED.
//
// Extends mmu_scoreboard_base, which supplies the strict, microarch-agnostic
// 4-case ladder. This class re-adds the C910 behaviours the base intentionally
// omits, all through the base's virtual seams:
//
//   check_bypass()                  M-mode bypasses translation, but the sysmap
//                                   and PMP still classify the PA.
//   check_predicted_fault()         The two DUT fault sources Whisper cannot
//                                   model: per-PTE-fetch PMP during the walk,
//                                   and sysmap-SO / PMP on the final PA.
//   handle_fault_kind_mismatch()    C910 raises an ACCESS fault where Whisper
//                                   reports a page fault (fault-priority).
//   handle_model_fault_dut_success() SUM/MXR fold -- DvMmu exposes no setter,
//                                   so Whisper always walks with SUM=0/MXR=0.
//   leaf_grants()                   SUM also gates fetch on C910 (T-Head
//                                   deviation from priv-spec 12.1.1.2).
//   on_pmp_config()                 Do NOT program Whisper's PMP; C910 PMP
//                                   semantics differ, so we police it ourselves.
//
// The predictors themselves live in mmu_c910_pma_pmp -- see that file for the
// RTL each one mirrors.
//
// Two base hooks are deliberately NOT overridden: handle_pa_mismatch and
// handle_model_success_dut_fault. Case A PA divergence and "Whisper OK but DUT
// faulted" have no C910 exception, and stay strict errors.
//======================================================================

`ifndef MMU_SCOREBOARD_SV
`define MMU_SCOREBOARD_SV

class mmu_scoreboard extends mmu_scoreboard_base;
  `uvm_component_utils(mmu_scoreboard)

  // C910 PMA (sysmap) + PMP fault predictor. Whisper models neither, so this
  // supplies every expected ACCESS fault; it also owns the observed PMP config.
  mmu_c910_pma_pmp pma_pmp;

  // Set by check_predicted_fault() for the current transaction, read back by
  // handle_fault_kind_mismatch() -- a walk-PMP deny is one of the conditions
  // that lets a DUT access fault preempt a Whisper page fault.
  protected bit walk_pmp;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    pma_pmp = mmu_c910_pma_pmp::type_id::create("pma_pmp");
  endfunction

  protected virtual function void refresh_walk_ctx();
    super.refresh_walk_ctx();
    // The predictor re-walks Sv39 for its per-PTE-fetch check, so it needs the
    // same context the base's walker uses.
    pma_pmp.refresh(mem, satp_root_ppn, satp_sv39);
  endfunction

  // Whisper PMP is DELIBERATELY NOT PROGRAMMED (left permissive). Whisper's own
  // page-walk PMP model checks every PTE fetch as READ-as-User, which diverges
  // from the C910 (ct_mmu_ptw.v ptw_pmp_deny checks the PTE fetch by the
  // ORIGINATING access type: fetch->X, load->R, store->W, + the M-lock gate).
  // Randomized deny regions may overlap the page tables, so programming the real
  // config into Whisper would make its walk PMP-fault with the wrong (R-only)
  // semantics and pollute the reference. mmu_c910_pma_pmp owns ALL PMP instead.
  protected virtual function void on_pmp_config(mmu_pmp_config cfg);
    pma_pmp.set_pmp(cfg);
  endfunction

  // SUM ALSO GATES FETCH on C910 -- a documented T-Head deviation. The C910
  // manual (Ch.17, mstatus) defines SUM over "load, store, and fetch requests",
  // and ct_mmu_iutlb.v:599 implements it (U && supv && !SUM -> inst page fault).
  // RISC-V (priv spec 12.1.1.2) instead states S-mode "can never execute
  // instructions from user pages, regardless of the state of SUM", which is what
  // the base models -- hence the Case-D fold. MXR stays load-only in both.
  protected virtual function bit leaf_grants(longint unsigned leaf,
                                             bit is_read, bit is_write, bit is_execute,
                                             bit [1:0] priv, bit sum, bit mxr);
    bit v = leaf[0], r = leaf[1], w = leaf[2], x = leaf[3], u = leaf[4];
    bit u_ok;
    if (!v) return 1'b0;
    u_ok = (priv == 2'b00) ? u : (u ? sum : 1'b1);   // U-mode: U=1; S-mode U-page: SUM
    if (!u_ok)       return 1'b0;
    if (is_execute)  return x;                       // u_ok already applied SUM
    if (is_write)    return w;
    return r || (mxr && x);                          // read (MXR opens X-only)
  endfunction : leaf_grants

  // M-mode BYPASSES translation (RTL: iutlb_off_hit = !mmu_en || cp0_mach_mode):
  // no walk, PA = VA page. But the C910 sysmap (PMA) and PMP still classify the
  // PA (PMP is NOT bypassed by M-mode unless the matched entry is UNLOCKED --
  // pma_pmp.pmp_deny()'s gate). Expected: PA = VA, no page fault, acc-fault =
  // sysmap SO (fetch only) OR PMP deny.
  protected virtual function void check_bypass(xlate_ctx_t c);
    bit    so_hit, pmp_hit, exp_acc;
    string fold;
    so_hit  = c.is_execute && pma_pmp.sysmap_so(c.va[39:12]);
    pmp_hit = pma_pmp.pmp_deny(c.va[39:12], c.priv, c.is_read, c.is_write, c.is_execute, c.is_pipe0);
    exp_acc = so_hit || pmp_hit;
    fold    = !exp_acc ? "none" : (pmp_hit ? (so_hit ? "SO+PMP" : "PMP") : "SO");
    if (!c.dut_page_fault && c.dut_pa === c.va[39:12] && c.dut_acc_fault === exp_acc) begin
      num_match++;
      `uvm_info(get_type_name(),
        $sformatf("%s: va=0x%0h M-mode BYPASS pa=0x%0h acc=%0b(%s) -> MATCH",
                  c.tag, c.va, c.dut_pa, c.dut_acc_fault, fold), UVM_MEDIUM)
    end
    else begin
      num_mismatch++;
      `uvm_error(get_type_name(),
        $sformatf("%s MISMATCH [M-bypass/%s]: va=0x%0h exp pa=0x%0h pgflt=0 acc=%0b, got pa=0x%0h pgflt=%0b acc=%0b",
                  c.tag, fold, c.va, c.va[39:12], exp_acc, c.dut_pa, c.dut_page_fault, c.dut_acc_fault))
    end
  endfunction : check_bypass

  // The two DUT fault sources Whisper cannot predict. Both fully score the
  // transaction and skip the ladder when they fire.
  protected virtual function bit check_predicted_fault(xlate_ctx_t c);
    bit    so_hit, pmp_hit;
    string fold;

    // Walk-time PMP (per-PTE-read) -- HIGHEST priority: a PTE fetch denied by
    // PMP raises a DUT ACCESS fault that aborts the walk before the leaf, so it
    // wins over both a successful and a page-faulting Whisper result.
    // The prediction is conditional on a walk actually happening: the hardware
    // only fetches PTEs on a jTLB miss (ct_mmu_ptw.v gates the walk on
    // ptw_jtlb_imiss), so a translation served from the TLB never evaluates
    // ptw_pmp_deny. We cannot observe residency, so we infer it from the DUT's
    // own answer -- a page fault means it resolved the translation without
    // fetching PTEs through the denied region.
    walk_pmp = pma_pmp.walk_pmp_deny(c.va, c.priv, c.is_read, c.is_write, c.is_execute);
    if (walk_pmp) begin
      if (c.dut_acc_fault && !c.dut_page_fault) begin
        num_match++;
        `uvm_info(get_type_name(),
          $sformatf("%s: va=0x%0h PTE-fetch PMP deny -> DUT walk acc-fault -> MATCH", c.tag, c.va), UVM_MEDIUM)
        return 1'b1;
      end
      else if (c.dut_page_fault) begin
        // No PTE fetch was issued -- fall through to the ladder and let the
        // page fault be scored on its merits. walk_pmp stays set, so Case B can
        // still use it as an acc_preempt condition.
        `uvm_info(get_type_name(),
          $sformatf("%s: va=0x%0h walk-PMP deny predicted but DUT page-faulted (no walk) -> ladder",
                    c.tag, c.va), UVM_HIGH)
      end
      else begin
        // DUT translated cleanly through a region we predict would deny a PTE
        // fetch. Not explainable by a TLB hit alone -- stay strict.
        num_mismatch++;
        `uvm_error(get_type_name(),
          $sformatf("%s MISMATCH [WalkPMP]: va=0x%0h expected walk acc-fault, got pgflt=%0b acc=%0b",
                    c.tag, c.va, c.dut_page_fault, c.dut_acc_fault))
        return 1'b1;
      end
    end

    // Sysmap PMA + PMP on the final PA: a successful Whisper walk whose PA is
    // either sysmap strong-ordered (fetch only) or PMP-denied still raises a DUT
    // ACCESS fault that wins over success. SO and PMP are independent DUT
    // mechanisms, so OR them into one expectation.
    so_hit  = c.is_execute && pma_pmp.sysmap_so(c.pa[39:12]);
    pmp_hit = pma_pmp.pmp_deny(c.pa[39:12], c.priv, c.is_read, c.is_write, c.is_execute, c.is_pipe0);
    if (!c.w_fault && (so_hit || pmp_hit)) begin
      fold = pmp_hit ? (so_hit ? "SO+PMP" : "PMP") : "SO";
      if (c.dut_acc_fault && !c.dut_page_fault) begin
        num_match++;
        `uvm_info(get_type_name(),
          $sformatf("%s: va=0x%0h Whisper OK but PA=0x%0h [%s] -> DUT acc-fault -> MATCH",
                    c.tag, c.va, c.pa[39:12], fold), UVM_MEDIUM)
      end
      else begin
        num_mismatch++;
        `uvm_error(get_type_name(),
          $sformatf("%s MISMATCH [%s]: va=0x%0h PA=0x%0h expected acc-fault, got pgflt=%0b acc=%0b",
                    c.tag, fold, c.va, c.pa[39:12], c.dut_page_fault, c.dut_acc_fault))
      end
      return 1'b1;
    end

    return 1'b0;
  endfunction : check_predicted_fault

  // Case B fault-PRIORITY fold: a leaf can satisfy BOTH a page-fault condition
  // (e.g. A=0 -> Whisper INST_PAGE_FAULT) AND an access-fault condition on the
  // translated PA (sysmap strong-order on a fetch, or PMP/walk-PMP deny). C910
  // raises the ACCESS fault in that case (the physical access is attempted / the
  // deny is a registered access fault), which preempts the page fault. Whisper
  // models neither SO nor C910 PMP, so it reports the page fault. So when
  // Whisper=page-fault but DUT=access-fault and the DUT's PA is SO (fetch) or
  // PMP-denied (or the walk PTE was PMP-denied), the DUT is correct -> MATCH.
  protected virtual function bit handle_fault_kind_mismatch(xlate_ctx_t c);
    bit dut_pa_so  = c.is_execute && pma_pmp.sysmap_so(c.dut_pa);
    bit dut_pa_pmp = pma_pmp.pmp_deny(c.dut_pa, c.priv, c.is_read, c.is_write, c.is_execute, c.is_pipe0);
    bit acc_preempt = c.dut_acc_fault && !c.dut_page_fault && c.w_pgflt &&
                      (dut_pa_so || dut_pa_pmp || walk_pmp);
    if (!acc_preempt) return 1'b0;
    num_match++;
    `uvm_info(get_type_name(),
      $sformatf("%s: va=0x%0h both FAULT (Whisper %s) [DUT acc-fault preempts page-fault] -> MATCH",
                c.tag, c.va, c.cause.name()), UVM_MEDIUM)
    return 1'b1;
  endfunction : handle_fault_kind_mismatch

  // Case D: Whisper always runs SUM=0/MXR=0 (DvMmu exposes no setter), so a leaf
  // the DUT's SUM/MXR permits but the (0,0) defaults reject lands here. Fold to
  // MATCH iff the (0,0) model page-denies, the (sum,mxr) model grants, and the
  // PA matches -- isolating exactly the SUM/MXR difference (A/D/reserved faults
  // are Case B/C, not here). PA compare is 4KB-only: superpages don't generate
  // yet, and one would simply fail pa_ok and surface as a mismatch, not a false
  // pass.
  protected virtual function bit handle_model_fault_dut_success(xlate_ctx_t c);
    longint unsigned leaf = leaf_pte_walk(c.va);
    bit fold_ok = c.w_pgflt && leaf[0] && (c.dut_pa === leaf[37:10]) &&
                  !leaf_grants(leaf, c.is_read, c.is_write, c.is_execute, c.priv, 1'b0, 1'b0) &&
                   leaf_grants(leaf, c.is_read, c.is_write, c.is_execute, c.priv, c.sum, c.mxr);
    if (!fold_ok) return 1'b0;
    num_match++;
    `uvm_info(get_type_name(),
      $sformatf("%s: va=0x%0h Whisper FAULT(%s) folded by SUM=%0b/MXR=%0b -> DUT ppn=0x%0h -> MATCH",
                c.tag, c.va, c.cause.name(), c.sum, c.mxr, c.dut_pa), UVM_MEDIUM)
    return 1'b1;
  endfunction : handle_model_fault_dut_success

endclass : mmu_scoreboard

`endif // MMU_SCOREBOARD_SV
