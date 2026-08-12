// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_dynamic_satp_seq.sv
//
// Dynamic satp context-switch sequence, scaled to C910: single-stage,
// Bare/Sv39 only, no H/VMID/world. Extends
// mmu_base_seq for the one-time setup of the first context, then performs
// num_switches-1 further context switches. Per switch it picks an UPDATE TYPE
// and derives {regen_pt, invalidate, new_asid}:
//
//   ASID_ONLY : no PT regen; INV_ASID iff the ASID is reused (stale), else none
//   PPN_ONLY  : regen PT; INV_ALL   (full regen -> every live ASID stale)
//   PPN_ASID  : regen PT; reused ASID -> INV_ALL, new ASID -> none
//   MODE_*    : regen PT (Bare<->Sv39); INV_ALL (mode can't be ASID-scoped)
//   + PMP/PMA re-rand (~6% of switches, deliberately rare): INV_ALL after reprogram
//
// Ordering invariant per switch (spec: "may be necessary to SFENCE.VMA prior to
// writing satp" + ASID-tagged TLB):
//   quiesce (wait MMU idle) -> invalidate -> regen PT + clear-old + preload
//   (sysmem+Whisper) -> write satp (DUT + Whisper + republish ctx) -> PMP/PMA
//   -> drive a full batch of translations.
//
// Global pages: OFF here (our mmu_pt_config_gen emits G=0), so the ASID-scoped
// cases are sound. A gated fixed-global-page mode is added separately.
//======================================================================
`ifndef MMU_DYNAMIC_SATP_SEQ_SV
`define MMU_DYNAMIC_SATP_SEQ_SV

class mmu_dynamic_satp_seq extends mmu_base_seq;
  `uvm_object_utils(mmu_dynamic_satp_seq)

  // Single-stage satp update types. C910 single-stage satp is ALWAYS a
  // translating mode (Sv39) -- DISABLE/Bare is forbidden for a
  // single-stage context ("disable creates no pages, invalid config"; Bare is
  // only a per-stage mode in two-stage/H-ext, which C910 lacks). "No translation"
  // is exercised at runtime via M-mode traffic (iutlb_off_hit bypass), NOT by a
  // Bare page table. So there are no MODE-change types here.
  typedef enum bit [1:0] {
    SATP_ASID_ONLY, SATP_PPN_ONLY, SATP_PPN_ASID
  } satp_upd_e;

  int unsigned num_switches;              // resolved 5..7 (+MMU_NUM_SATP_SWITCHES)
  int unsigned asid_reuse_pct = 50;       // +MMU_SATP_ASID_REUSE_PCT
  int unsigned pma_pmp_pct    = 6;        // +MMU_SATP_PMA_PMP_PCT (deliberately rare)
  bit [15:0]   used_asids[$];             // ASID reuse pool
  int unsigned pt_base_seed = 1;

  // End-of-run tallies.
  int unsigned type_cnt[satp_upd_e];      // per update-type count
  int unsigned inv_cnt[mmu_inv_kind_e];   // per invalidation-kind count
  int unsigned no_inv_cnt;                // switches that needed no flush

  function new(string name = "mmu_dynamic_satp_seq");
    super.new(name);
  endfunction

  // Enable the fixed global-page set BEFORE the base one-time setup so context
  // #1 already includes it (+MMU_SATP_ENABLE_GLOBAL_PAGES). Persists for every
  // subsequent regen (use_global_pages is a member).
  virtual task body();
    use_global_pages = $test$plusargs("MMU_SATP_ENABLE_GLOBAL_PAGES");
    if (use_global_pages)
      `uvm_info("MMU_DYN_SATP", "fixed global pages ENABLED (persist across switches)", UVM_LOW)
    super.body();
  endtask

  protected function int unsigned resolve_num_switches();
    int unsigned v;
    if ($value$plusargs("MMU_NUM_SATP_SWITCHES=%d", v)) return v;
    return $urandom_range(5, 7);
  endfunction

  // Single-stage update-type weights (ASID-heavy), re-normalized to the three
  // Sv39 types (45/20/23 -> 51/23/26).
  protected function satp_upd_e pick_update_type();
    int unsigned r = $urandom_range(0, 99);
    if      (r < 51) return SATP_ASID_ONLY;
    else if (r < 74) return SATP_PPN_ONLY;
    else             return SATP_PPN_ASID;
  endfunction

  // Choose the next ASID: reuse an existing one (asid_reuse_pct) or a fresh one.
  // Returns reused=1 if the chosen ASID was already in the pool.
  protected function bit [15:0] next_asid(output bit reused);
    bit [15:0] a;
    reused = 1'b0;
    if (used_asids.size() > 0 && $urandom_range(0, 99) < asid_reuse_pct) begin
      a = used_asids[$urandom_range(0, used_asids.size()-1)];
      reused = 1'b1;
    end
    else begin
      // fresh ASID not already in the pool (bounded attempts)
      for (int t = 0; t < 32; t++) begin
        a = $urandom_range(16'h100, 16'hFFF);
        if (!(a inside {used_asids})) break;
      end
      used_asids.push_back(a);
    end
    return a;
  endfunction

  // Quiesce the MMU (wait mmu_yy_xx_no_op) before touching the context, so the
  // invalidation and satp swap land between translations -- not mid-walk. Issued
  // as a CTX_SET (S-mode, PTW on) with wait_idle; the prior batch has already
  // returned, so idle is reachable. MUST precede the invalidate (else INV_ALL
  // can be launched while the MMU is still busy and never completes).
  protected task do_quiesce();
    mmu_csr_seq_item q = mmu_csr_seq_item::type_id::create("quiesce");
    if (p_sequencer.csr_sqr == null) `uvm_fatal("MMU_DYN_SATP", "csr_sqr null")
    start_item(q, -1, p_sequencer.csr_sqr);
    if (!q.randomize() with {
          q.op == mmu_csr_seq_item::CTX_SET; q.priv_mode == 2'b01;   // S-mode
          q.mprv == 1'b0; q.mpp == 2'b00; q.mxr == 1'b0; q.sum == 1'b0;
          q.ptw_en == 1'b1; q.maee == 1'b0; q.cskyee == 1'b0; })
      `uvm_error("MMU_DYN_SATP", "quiesce CTX_SET randomize failed")
    q.wait_idle = 1'b1;
    finish_item(q);
  endtask

  // Drive one invalidation kind on inv_sqr and wait its done (driver handles the
  // LSU-vs-CP0 done selection). asid used only for INV_ASID.
  protected task do_invalidate(mmu_inv_kind_e kind, bit [15:0] asid = 16'h0);
    mmu_tlb_inv_seq_item it = mmu_tlb_inv_seq_item::type_id::create("inv");
    if (p_sequencer.inv_sqr == null)
      `uvm_fatal("MMU_DYN_SATP", "inv_sqr is null")
    start_item(it, -1, p_sequencer.inv_sqr);
    if (!it.randomize() with { it.asid == asid; it.vpn == 27'h0; })
      `uvm_error("MMU_DYN_SATP", "inv item randomize failed")
    // Set kind by ASSIGNMENT, not constraint: a cast-to-enum in an inline
    // constraint solved to an out-of-range kind on Verilator -> driver drove no
    // strobe -> no done -> watchdog timeout (blank kind name in the error).
    it.kind = kind;
    finish_item(it);
    inv_cnt[kind]++;
  endtask

  // One full batch of translations for the current context (IFU + LSU forked),
  // reusing the child unit seqs with skip_setup (parent owns the context).
  protected task drive_batch();
    mmu_ifu_seq ifu = mmu_ifu_seq::type_id::create("dyn_ifu");
    mmu_lsu_seq lsu = mmu_lsu_seq::type_id::create("dyn_lsu");
    int unsigned reqs = resolve_num_reqs();
    ifu.skip_setup = 1'b1; ifu.switch_priv = 1'b1;
    ifu.num_of_reqs = reqs / 2;
    ifu.va_entries = va_entries; ifu.satp_ppn = satp_ppn; ifu.satp_mode = satp_mode;
    lsu.skip_setup = 1'b1; lsu.switch_priv = 1'b1;
    lsu.num_of_reqs = reqs;
    lsu.va_entries = va_entries; lsu.satp_ppn = satp_ppn; lsu.satp_mode = satp_mode;
    fork
      ifu.start(p_sequencer);
      lsu.start(p_sequencer);
    join
  endtask

  // Optional rare PMP/PMA re-randomization for the current context, then INV_ALL.
  protected task maybe_pmp_pma_rerand(int idx);
    mmu_pmp_update_seq useq;
    if ($urandom_range(0, 99) >= pma_pmp_pct) return;        // ~94% no-op
    if (p_sequencer.pmp_sqr == null) return;
    useq = mmu_pmp_update_seq::type_id::create("dyn_pmp");
    useq.rand_seed  = pt_base_seed + idx + 100;
    useq.win_lo_ppn = {1'b0, PMP_WIN_LO_PPN};
    useq.win_hi_ppn = PMP_WIN_HI_PPN;
    foreach (pte_entries[i]) useq.pte_ppns.push_back(pte_entries[i].addr[39:12]);
    useq.start(p_sequencer.pmp_sqr);
    `uvm_info("MMU_DYN_SATP", "per-context PMP/PMA re-randomized -> INV_ALL", UVM_LOW)
    do_invalidate(INV_ALL);
  endtask

  //--------------------------------------------------------------------
  // One context switch.
  //--------------------------------------------------------------------
  protected task do_switch(int idx);
    satp_upd_e upd = pick_update_type();
    bit        reused;
    bit [15:0] old_asid = gen_asid;
    bit        regen = 1'b1;
    bit [15:0] new_asid = gen_asid;

    // Decide fields per update type (Sv39 throughout; no mode change).
    case (upd)
      SATP_ASID_ONLY: begin regen = 1'b0; new_asid = next_asid(reused); end
      SATP_PPN_ONLY : begin regen = 1'b1; end                              // same ASID
      SATP_PPN_ASID : begin regen = 1'b1; new_asid = next_asid(reused); end
    endcase

    type_cnt[upd]++;
    // One-line summary: old{mode,asid,ppn} -> new{...} | invl regen.
    // (mode is always SV39 on C910 single-stage; PPN old is the current
    // satp_ppn, new PPN is filled in after regen in the log below.)
    `uvm_info("MMU_DYN_SATP", $sformatf(
      "switch #%0d: %s | old[mode=SV39 asid=0x%0h ppn=0x%0h] -> new[mode=SV39 asid=0x%0h ppn=<regen>] | regen=%0b reused=%0b",
      idx, upd.name(), old_asid, satp_ppn, new_asid, regen, reused), UVM_LOW)

    // 1) Quiesce FIRST so the invalidate + satp swap land between translations
    //    (INV_ALL launched on a busy MMU can never complete -> driver timeout ->
    //    incomplete flush -> stale TLB hits).
    do_quiesce();

    // 2) Invalidate per the locked table.
    if (upd == SATP_ASID_ONLY) begin
      if (reused) do_invalidate(INV_ASID, new_asid);          // stale reused ASID
    end
    else if (upd == SATP_PPN_ONLY) begin
      do_invalidate(INV_ALL);                                 // full regen, same ASID
    end
    else begin // SATP_PPN_ASID
      // Always flush: this update type regenerates the page tables (regen=1), and
      // changing a mapping requires an sfence.vma regardless of ASID.
      //
      // The old "new ASID -> no flush (can't alias)" reasoning only holds for the
      // jTLB, which is ASID-tagged. C910's micro-TLBs are NOT: ct_mmu_iutlb_entry /
      // ct_mmu_dutlb_entry hold only {vld, vpn, ppn, pgs} -- no ASID, no global bit
      // (which is also why the invalidation checker flushes them coarsely). A stale
      // uTLB entry therefore hits under ANY ASID, so a fresh ASID gives no
      // protection once the underlying mapping has changed, and the DUT correctly
      // returns the previous context's PPN while the reference returns the new one.
      do_invalidate(INV_ALL);
    end
    if (upd == SATP_ASID_ONLY && !reused) no_inv_cnt++;       // new ASID -> no flush

    // 3) New context: regen (if needed) + clear-old + preload.
    if (regen) begin
      clear_old_ptes();
      has_ctx_seed  = 1'b1;  ctx_seed = pt_base_seed + idx + 1;
      force_asid_en = 1'b1;  forced_asid = new_asid;
      generate_page_tables();     // new pte_entries/va_entries/satp_ppn (Sv39)
      preload_ptes();
    end
    else begin
      // ASID_ONLY: reuse PT/VAs, just change the ASID in satp.
      gen_asid = new_asid;
    end

    // 4) Install satp (quiesce first), mirror Whisper, republish ctx.
    satp_wait_idle = 1'b1;
    program_satp();
    satp_wait_idle = 1'b0;
    `uvm_info("MMU_DYN_SATP", $sformatf(
      "switch #%0d installed: mode=SV39 asid=0x%0h ppn=0x%0h", idx, gen_asid, satp_ppn), UVM_LOW)

    // 5) Rare per-context PMP/PMA re-rand (+ its own INV_ALL).
    maybe_pmp_pma_rerand(idx);

    // 6) Drive the batch under the new context.
    drive_batch();
  endtask

  //--------------------------------------------------------------------
  // drive_stimulus: base body() already set up + we owe switch #1's batch,
  // then num_switches-1 more switches.
  //--------------------------------------------------------------------
  virtual task drive_stimulus();
    void'($value$plusargs("PT_SEED=%d", pt_base_seed));
    void'($value$plusargs("MMU_SATP_ASID_REUSE_PCT=%d", asid_reuse_pct));
    void'($value$plusargs("MMU_SATP_PMA_PMP_PCT=%d", pma_pmp_pct));
    num_switches = resolve_num_switches();
    used_asids.push_back(gen_asid);   // context #1's ASID is in the pool
    `uvm_info("MMU_DYN_SATP",
      $sformatf("dynamic satp: %0d contexts (switch #1 + %0d switches)",
                num_switches, num_switches-1), UVM_LOW)

    drive_batch();                    // context #1 (setup done by base body())
    for (int i = 1; i < num_switches; i++)
      do_switch(i);
    print_summary();
  endtask

  // End-of-run tally: update-type histogram + invalidation counts.
  protected function void print_summary();
    satp_upd_e     u;
    mmu_inv_kind_e k;
    int unsigned   inv_total = 0;
    `uvm_info("MMU_DYN_SATP", "================ DYNAMIC SATP SUMMARY ================", UVM_LOW)
    `uvm_info("MMU_DYN_SATP", $sformatf("contexts (switches) : %0d", num_switches), UVM_LOW)
    `uvm_info("MMU_DYN_SATP", $sformatf("distinct ASIDs used : %0d", used_asids.size()), UVM_LOW)
    `uvm_info("MMU_DYN_SATP", "--- update-type counts ---", UVM_LOW)
    u = u.first();
    forever begin
      `uvm_info("MMU_DYN_SATP", $sformatf("  %-16s : %0d", u.name(), type_cnt[u]), UVM_LOW)
      if (u == u.last()) break; u = u.next();
    end
    `uvm_info("MMU_DYN_SATP", "--- invalidation counts ---", UVM_LOW)
    k = k.first();
    forever begin
      `uvm_info("MMU_DYN_SATP", $sformatf("  %-12s : %0d", k.name(), inv_cnt[k]), UVM_LOW)
      inv_total += inv_cnt[k];
      if (k == k.last()) break; k = k.next();
    end
    `uvm_info("MMU_DYN_SATP", $sformatf("  (no-flush)   : %0d  |  total invalidations : %0d",
              no_inv_cnt, inv_total), UVM_LOW)
    `uvm_info("MMU_DYN_SATP", "=====================================================", UVM_LOW)
  endfunction

endclass : mmu_dynamic_satp_seq

`endif // MMU_DYNAMIC_SATP_SEQ_SV
