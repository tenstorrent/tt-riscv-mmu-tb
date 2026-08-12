// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_scoreboard_base.sv
//
// DUT-vs-reference-model MMU scoreboard -- BASE (generic, strict).
//
// Microarchitecture-agnostic: for every IFU/LSU translation it runs the
// reference model and compares against the DUT with a strict 4-case ladder:
//   A. model success + DUT success -> compare physical page number
//   B. model fault   + DUT fault   -> compare fault KIND (page vs access)
//   C. model success + DUT fault   -> uvm_error
//   D. model fault   + DUT success -> uvm_error
//
// A spec-compliant MMU matches the reference exactly, so ANY divergence in
// B/C/D is a uvm_error here. DUT-specific reconciliations are NOT in this
// class -- a derived class adds them through the virtual hooks below, whose
// base implementations are all inert (return 0 = "not handled, stay strict").
//
// The two seams that are NOT divergence-reconciliation:
//   check_bypass()          - what a translation-bypassed access should look
//                             like (base: PA = VA, no fault).
//   check_predicted_fault() - a DUT mechanism the reference does not model at
//                             all, so the expected fault must be PREDICTED
//                             rather than reconciled (base: predicts nothing).
//
// Everything the hooks need travels in xlate_ctx_t rather than long argument
// lists, so adding a field does not churn every override.
//======================================================================

`ifndef MMU_SCOREBOARD_BASE_SV
`define MMU_SCOREBOARD_BASE_SV

`uvm_analysis_imp_decl(_ifu)
`uvm_analysis_imp_decl(_lsu)
`uvm_analysis_imp_decl(_pmp)

class mmu_scoreboard_base extends uvm_scoreboard;
  `uvm_component_utils(mmu_scoreboard_base)

  uvm_analysis_imp_ifu #(mmu_ifu_seq_item, mmu_scoreboard_base) ifu_imp;
  uvm_analysis_imp_lsu #(mmu_lsu_seq_item, mmu_scoreboard_base) lsu_imp;
  // PMP config observer: the PMP config-manager agent's monitor re-broadcasts
  // every applied 16-entry config here (once at reset with the all-permissive
  // default, and again whenever a test drives a new one).
  uvm_analysis_imp_pmp #(mmu_pmp_config, mmu_scoreboard_base) pmp_imp;

  // Reference-model wrapper (connected by the env).
  whisper_dv_mmu wh;

  // Shared DUT/TB physical memory (same handle the ptw_mem responder uses),
  // fetched lazily from the config_db ("mmu_mem"). leaf_pte_walk() reads PTEs
  // from it.
  mmu_sysmem mem;

  // satp root PPN + mode, published by the base seq after program_satp().
  bit [27:0] satp_root_ppn;
  bit        satp_sv39;

  // MMR base addresses the reference model treats as its pmpcfg/pmpaddr
  // register windows. DvMmu's MMR space is its own opaque byte-addressed
  // window indexed as (addr-base)/8, so only 8-byte alignment and a flat
  // 8-byte stride matter; these values just echo the RISC-V CSR numbers
  // (pmpcfg0=0x3A0, pmpaddr0=0x3B0) for readability.
  localparam longint unsigned PMP_CFG_ADDR  = 64'h3A0;
  localparam longint unsigned PMP_ADDR_ADDR = 64'h3B0;

  int unsigned num_checked, num_match, num_mismatch;

  // Everything one translation check needs. Fields above the divider are set
  // by the caller; the rest are filled in once the reference model has run.
  typedef struct {
    longint unsigned         va;
    bit                      is_read, is_write, is_execute, is_pipe0;
    bit [27:0]               dut_pa;
    bit                      dut_page_fault, dut_acc_fault;
    bit [1:0]                priv;
    bit                      sum, mxr;
    string                   tag;
    //---
    longint unsigned         pa;
    dv_mmu_exception_cause_e cause;
    bit                      w_fault, w_pgflt, w_accflt, dut_fault;
  } xlate_ctx_t;

  // Functional-coverage feed: one resolved-translation event per check_xlate
  // (stimulus + reference prediction, NOT the DUT-vs-ref verdict). The env
  // connects this to the mmu_cov_collector.
  uvm_analysis_port #(mmu_xlate_result) xlate_ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ifu_imp = new("ifu_imp", this);
    lsu_imp = new("lsu_imp", this);
    pmp_imp = new("pmp_imp", this);
    xlate_ap = new("xlate_ap", this);
  endfunction

  // Emit one functional-coverage event for a resolved translation. acc is
  // derived from the access booleans; mode/fault are classified by the caller.
  protected function void emit_cov(xlate_ctx_t c,
                                   mmu_cov_mode_e  mode,
                                   mmu_cov_fault_e fault,
                                   bit             leaf_valid = 1'b0,
                                   longint unsigned leaf_pte   = '0);
    mmu_xlate_result r;
    r = mmu_xlate_result::type_id::create("xlate_result");
    r.va         = c.va;
    r.priv       = mmu_cov_priv_e'(c.priv);
    r.acc        = c.is_execute ? MMU_COV_ACC_FETCH
                 : (c.is_write  ? MMU_COV_ACC_STORE : MMU_COV_ACC_LOAD);
    r.mode       = mode;
    r.fault      = fault;
    r.leaf_valid = leaf_valid;
    r.leaf_pte   = leaf_pte;
    xlate_ap.write(r);
  endfunction

  // Lazily fetch the shared memory + satp context (published after build/reset:
  // mem via config_db "mmu_mem" in the env, satp by the base seq).
  protected virtual function void refresh_walk_ctx();
    if (mem == null)
      void'(uvm_config_db#(mmu_sysmem)::get(this, "", "mmu_mem", mem));
    void'(uvm_config_db#(bit [27:0])::get(this, "", "satp_root_ppn", satp_root_ppn));
    void'(uvm_config_db#(bit)::get(this, "", "satp_sv39", satp_sv39));
  endfunction

  //--------------------------------------------------------------------
  // Generic Sv39 helpers, available to derived classes.
  //--------------------------------------------------------------------

  // Re-walk Sv39 from satp_root_ppn and return the leaf PTE (0 if the walk hits
  // an invalid PTE or finds no leaf).
  protected function longint unsigned leaf_pte_walk(longint unsigned va);
    bit [26:0]       vpn[3];
    bit [27:0]       node_ppn;
    longint unsigned pte_addr, pte;
    if (!satp_sv39 || mem == null) return '0;
    // No walk happens for a non-canonical Sv39 VA, so there is no leaf.
    if (va[63:39] != {25{va[38]}}) return '0;
    vpn[0] = va[20:12];
    vpn[1] = va[29:21];
    vpn[2] = va[38:30];
    node_ppn = satp_root_ppn;
    for (int lvl = 2; lvl >= 0; lvl--) begin
      pte_addr = ({node_ppn, 12'b0}) + (longint'(vpn[lvl]) << 3);
      pte = mem.read_8(pte_addr);
      if (!pte[0])           return '0;    // invalid PTE
      if (pte[1] || pte[3])  return pte;   // leaf (R=1 or X=1)
      node_ppn = pte[37:10];               // descend
    end
    return '0;                             // no leaf within 3 levels
  endfunction : leaf_pte_walk

  // Does an Sv39 leaf grant this access under (priv, sum, mxr)?
  //
  // RISC-V semantics (priv spec 12.1.1.2): SUM covers loads and stores only --
  // S-mode "can never execute instructions from user pages, regardless of the
  // state of SUM". MXR opens X-only pages to loads. A DUT that deviates
  // overrides this.
  protected virtual function bit leaf_grants(longint unsigned leaf,
                                             bit is_read, bit is_write, bit is_execute,
                                             bit [1:0] priv, bit sum, bit mxr);
    bit v = leaf[0], r = leaf[1], w = leaf[2], x = leaf[3], u = leaf[4];
    if (!v) return 1'b0;
    if (priv == 2'b00) begin
      if (!u) return 1'b0;                 // U-mode needs a user page
    end
    else begin
      if (u && (is_execute || !sum)) return 1'b0;  // S-mode on a user page
    end
    if (is_execute)  return x;
    if (is_write)    return w;
    return r || (mxr && x);
  endfunction : leaf_grants

  //--------------------------------------------------------------------
  // Virtual seams. Every base default keeps the ladder strict.
  //--------------------------------------------------------------------

  // Does this access bypass translation entirely?
  protected virtual function bit is_bypass(bit [1:0] priv);
    return (priv === 2'b11);   // M-mode
  endfunction

  // Score a bypassed access. Base expectation: PA = VA page, no fault at all.
  protected virtual function void check_bypass(xlate_ctx_t c);
    if (!c.dut_page_fault && !c.dut_acc_fault && c.dut_pa === c.va[39:12]) begin
      num_match++;
      `uvm_info(get_type_name(),
        $sformatf("%s: va=0x%0h BYPASS pa=0x%0h -> MATCH", c.tag, c.va, c.dut_pa), UVM_MEDIUM)
    end
    else begin
      num_mismatch++;
      `uvm_error(get_type_name(),
        $sformatf("%s MISMATCH [bypass]: va=0x%0h exp pa=0x%0h pgflt=0 acc=0, got pa=0x%0h pgflt=%0b acc=%0b",
                  c.tag, c.va, c.va[39:12], c.dut_pa, c.dut_page_fault, c.dut_acc_fault))
    end
  endfunction

  // DUT fault mechanisms the reference model does not model at all, so the
  // expected fault has to be predicted. Runs BEFORE the ladder; return 1 if
  // this check is fully scored and the ladder should be skipped.
  protected virtual function bit check_predicted_fault(xlate_ctx_t c);
    return 1'b0;
  endfunction

  // Case A: PA divergence. Return 1 to suppress the strict error.
  protected virtual function bit handle_pa_mismatch(xlate_ctx_t c);
    return 1'b0;
  endfunction

  // Case B: both faulted but the KIND differs. Return 1 to suppress.
  protected virtual function bit handle_fault_kind_mismatch(xlate_ctx_t c);
    return 1'b0;
  endfunction

  // Case C: model success, DUT fault. Return 1 to suppress.
  protected virtual function bit handle_model_success_dut_fault(xlate_ctx_t c);
    return 1'b0;
  endfunction

  // Case D: model fault, DUT success. Return 1 to suppress.
  protected virtual function bit handle_model_fault_dut_success(xlate_ctx_t c);
    return 1'b0;
  endfunction

  //====================================================================
  // !! NEVER EXECUTED IN THIS REPO -- UNTESTED CODE !!
  //
  // What to do with an observed PMP config. This base implementation programs
  // the reference model's PMP so the model can police accesses itself, which is
  // the natural approach for a DUT whose PMP semantics match the model's.
  //
  // The C910 subclass OVERRIDES this to do nothing, because Whisper's page-walk
  // PMP checks every PTE fetch as READ-as-User while the C910 checks it by the
  // ORIGINATING access type (ct_mmu_ptw.v:648). Programming the real config into
  // Whisper would make its walk fault with the wrong semantics and pollute the
  // reference, so mmu_c910_pma_pmp polices PMP instead. That override is the
  // only path taken here, so NOTHING below has ever run.
  //
  // Kept because it encodes real DvMmu MMR-layout knowledge (see the encoding
  // notes on pmp_addr_to_csr) that a future DUT could reuse. Before trusting it:
  //   - it has never been compiled-and-run, only compiled;
  //   - pmp_addr_to_csr has a KNOWN TOR-after-NAPOT bug, documented there;
  //   - the MMR addresses/stride are DvMmu-specific, not portable to another
  //     reference model.
  //====================================================================
  protected virtual function void on_pmp_config(mmu_pmp_config cfg);
    longint unsigned pmpcfg[2], pmpaddr_ppn[16], data;
    if (wh == null) return;
    cfg.to_pmpcfg_pmpaddr(pmpcfg, pmpaddr_ppn);
    void'(wh.define_pmp_regs(PMP_CFG_ADDR, 2, PMP_ADDR_ADDR, 16));
    for (int i = 0; i < 2; i++) begin
      data = pmpcfg[i];
      void'(wh.mmr_write(PMP_CFG_ADDR + i*8, data));
    end
    for (int i = 0; i < 16; i++) begin
      data = pmp_addr_to_csr(cfg, i);
      void'(wh.mmr_write(PMP_ADDR_ADDR + i*8, data));
    end
  endfunction

  // !! NEVER EXECUTED IN THIS REPO -- called only from on_pmp_config() above,
  // !! which the C910 subclass overrides away. Untested; see the warning there.
  //
  // Convert entry i's PPN-domain address (addr[]/lo[]/hi[] are all PA>>12)
  // into the RISC-V pmpaddr CSR field (PA[55:2]).
  //
  // NAPOT: DvMmu (matching WdRiscv::Pmp) decodes region size from the index of
  // the CSR value's LOWEST ZERO bit (rzi): size = 2^(rzi+3) bytes, base = the
  // value with bits [0:rzi] cleared, shifted left by 2. Our model works at 4KB
  // granularity: an N-page region (N = hi-lo = 2^j) needs rzi = j+9 trailing
  // ones -- 9 mandatory low ones (the page granule, since PPN<<10 leaves the
  // low 10 CSR bits zero) plus j more from the size mask (hi-lo-1, which has
  // exactly j trailing ones by construction). Built from the floor-aligned
  // lo[i], not the raw addr[i]:
  //   pmpaddr_csr = (lo << 10) | ((hi-lo-1) << 9) | 9'h1FF
  // TOR/OFF: no NAPOT trick -- a plain PPN<<10 suffices.
  //
  // KNOWN BUG, UNFIXED: a TOR entry immediately following a NAPOT entry picks up
  // that entry's forced low-order NAPOT mask bits as its TOR lower bound,
  // because DvMmu's TOR "low" is the raw preceding pmpaddr value rather than a
  // re-derived floor. Harmless only because nothing calls this -- a DUT that
  // enables on_pmp_config() must fix it first, or avoid adjacent
  // NAPOT-then-TOR entries.
  protected function longint unsigned pmp_addr_to_csr(mmu_pmp_config cfg, int i);
    longint unsigned lo_u, m_u, addr_u;
    bit [28:0] m;
    if (cfg.mode[i] == mmu_pmp_config::PMP_NAPOT) begin
      m    = cfg.hi[i] - cfg.lo[i] - 29'd1;
      lo_u = cfg.lo[i];
      m_u  = m;
      return (lo_u << 10) | (m_u << 9) | 64'h1FF;
    end
    addr_u = cfg.addr[i];
    return addr_u << 10;
  endfunction : pmp_addr_to_csr

  //--------------------------------------------------------------------
  // Analysis write callbacks
  //--------------------------------------------------------------------

  // IFU: instruction fetch (execute). ifu_mmu_va is VA[63:1], so the byte VA is
  // {tr.va, 1'b0}. Fetch ignores MPRV, so cp0_yy_priv_mode is authoritative.
  virtual function void write_ifu(mmu_ifu_seq_item tr);
    xlate_ctx_t c;
    c.va             = {tr.va, 1'b0};
    c.is_read        = 1'b0;
    c.is_write       = 1'b0;
    c.is_execute     = 1'b1;
    // is_pipe0=0: fetch has is_read=0, and the IFU has no per-pipe R hardwiring.
    c.is_pipe0       = 1'b0;
    c.dut_pa         = tr.pa;
    c.dut_page_fault = (tr.pgflt === 1'b1);
    c.dut_acc_fault  = (tr.deny  === 1'b1);
    c.priv           = tr.priv_mode;
    c.sum            = (tr.sum === 1'b1);
    c.mxr            = 1'b0;          // MXR is load-only
    c.tag            = "IFU";
    check_xlate(c);
  endfunction

  // LSU: data load/store, full byte VA. Data accesses honor MPRV: the effective
  // privilege for both translation and PMP is (mprv ? mpp : priv_mode) -- unlike
  // fetch, which ignores MPRV. So M-mode with mprv=0 bypasses translation, and
  // mprv=1 & mpp=S makes M-mode actually walk.
  virtual function void write_lsu(mmu_lsu_seq_item tr);
    xlate_ctx_t c;
    c.va             = tr.va;
    c.is_read        = !tr.st_inst;
    c.is_write       = tr.st_inst;
    c.is_execute     = 1'b0;
    // tr.pipe is set by the LSU monitor from whichever pipe's response fired.
    c.is_pipe0       = (tr.pipe == 2'd0);
    c.dut_pa         = tr.pa;
    c.dut_page_fault = (tr.page_fault   === 1'b1);
    c.dut_acc_fault  = (tr.access_fault === 1'b1);
    c.priv           = tr.mprv ? tr.mpp : tr.priv_mode;
    c.sum            = tr.sum;
    c.mxr            = tr.mxr;
    c.tag            = tr.st_inst ? "LSU-ST" : "LSU-LD";
    check_xlate(c);
  endfunction

  virtual function void write_pmp(mmu_pmp_config cfg);
    mmu_pmp_config cfg_clone;
    cfg_clone      = mmu_pmp_config::type_id::create("cfg_clone");
    cfg_clone.mode = cfg.mode;
    cfg_clone.r    = cfg.r;
    cfg_clone.w    = cfg.w;
    cfg_clone.x    = cfg.x;
    cfg_clone.l    = cfg.l;
    cfg_clone.addr = cfg.addr;
    cfg_clone.lo   = cfg.lo;
    cfg_clone.hi   = cfg.hi;
    cfg_clone.vld  = cfg.vld;
    on_pmp_config(cfg_clone);
  endfunction : write_pmp

  //--------------------------------------------------------------------
  // The ladder. NON-VIRTUAL on purpose: its shape is invariant, and all
  // variability goes through the hooks above.
  //--------------------------------------------------------------------
  protected function void check_xlate(xlate_ctx_t c);
    longint unsigned gpa, walk_pa, leaf_pte;
    bit              ok, wc, vswc;
    bit [27:0]       w_ppn;

    if (wh == null) return;

    num_checked++;
    refresh_walk_ctx();

    if (is_bypass(c.priv)) begin
      // Coverage: M-mode/translation-off bypass. No walk, so no leaf PTE; the
      // fault classification comes from what the DUT reported (the bypass path
      // has no reference walk to predict from).
      emit_cov(c, MMU_COV_MODE_MBYPASS,
               c.dut_acc_fault ? MMU_COV_FLT_ACCESS
                               : (c.dut_page_fault ? MMU_COV_FLT_PAGE
                                                   : MMU_COV_FLT_NONE));
      check_bypass(c);
      return;
    end

    ok = wh.translate(c.va,
                      (c.priv === 2'b00) ? DV_MMU_PRIV_USER : DV_MMU_PRIV_SUPERVISOR,
                      1'b0 /*two_stage*/,
                      c.is_read, c.is_write, c.is_execute,
                      gpa, c.pa, c.cause, wc, walk_pa, leaf_pte, vswc);

    c.w_fault   = (c.cause != DV_MMU_CAUSE_NONE);
    c.w_pgflt   = (c.cause == DV_MMU_CAUSE_INST_PAGE_FAULT ||
                   c.cause == DV_MMU_CAUSE_LOAD_PAGE_FAULT  ||
                   c.cause == DV_MMU_CAUSE_STORE_PAGE_FAULT);
    c.w_accflt  = (c.cause == DV_MMU_CAUSE_INST_ACC_FAULT ||
                   c.cause == DV_MMU_CAUSE_LOAD_ACC_FAULT  ||
                   c.cause == DV_MMU_CAUSE_STORE_ACC_FAULT);
    c.dut_fault = c.dut_page_fault || c.dut_acc_fault;

    // Coverage: U/S paged path. Classify the fault from the REFERENCE walk
    // (access wins over page); leaf_pte is meaningful only when the walk
    // reached a valid leaf (V bit set). Emitted before the scoring ladder so
    // the sample is taken for every checked translation, pass or fail.
    emit_cov(c,
             satp_sv39 ? MMU_COV_MODE_SV39 : MMU_COV_MODE_BARE,
             c.w_accflt ? MMU_COV_FLT_ACCESS
                        : (c.w_pgflt ? MMU_COV_FLT_PAGE : MMU_COV_FLT_NONE),
             (leaf_pte[0] === 1'b1), leaf_pte);

    // DUT mechanisms the reference cannot predict -- scored before the ladder.
    if (check_predicted_fault(c)) return;

    if (!c.w_fault && !c.dut_fault) begin
      // Case A — both success: compare the physical page number.
      w_ppn = c.pa[39:12];
      if (w_ppn === c.dut_pa) begin
        num_match++;
        `uvm_info(get_type_name(),
          $sformatf("%s: va=0x%0h DUT ppn=0x%0h == Whisper ppn=0x%0h -> MATCH",
                    c.tag, c.va, c.dut_pa, w_ppn), UVM_MEDIUM)
      end
      else if (!handle_pa_mismatch(c)) begin
        num_mismatch++;
        `uvm_error(get_type_name(),
          $sformatf("%s MISMATCH [PA]: va=0x%0h Whisper ppn=0x%0h vs DUT ppn=0x%0h",
                    c.tag, c.va, w_ppn, c.dut_pa))
      end
    end
    else if (c.w_fault && c.dut_fault) begin
      // Case B — both fault: check the fault kind (page vs access) matches.
      bit kind_ok = (c.dut_page_fault && c.w_pgflt) || (c.dut_acc_fault && c.w_accflt);
      if (kind_ok) begin
        num_match++;
        `uvm_info(get_type_name(),
          $sformatf("%s: va=0x%0h both FAULT (Whisper %s) -> MATCH",
                    c.tag, c.va, c.cause.name()), UVM_MEDIUM)
      end
      else if (!handle_fault_kind_mismatch(c)) begin
        num_mismatch++;
        `uvm_error(get_type_name(),
          $sformatf("%s MISMATCH [FltKind]: va=0x%0h Whisper=%s vs DUT pgflt=%0b accflt=%0b",
                    c.tag, c.va, c.cause.name(), c.dut_page_fault, c.dut_acc_fault))
      end
    end
    else if (!c.w_fault && c.dut_fault) begin
      // Case C — model success, DUT fault.
      if (!handle_model_success_dut_fault(c)) begin
        num_mismatch++;
        `uvm_error(get_type_name(),
          $sformatf("%s MISMATCH: Whisper SUCCESS (ppn=0x%0h) but DUT FAULT (pg=%0b acc=%0b) va=0x%0h",
                    c.tag, c.pa[39:12], c.dut_page_fault, c.dut_acc_fault, c.va))
      end
    end
    else begin
      // Case D — model fault, DUT success.
      if (!handle_model_fault_dut_success(c)) begin
        num_mismatch++;
        `uvm_error(get_type_name(),
          $sformatf("%s MISMATCH: Whisper FAULT (%s) but DUT SUCCESS (ppn=0x%0h) va=0x%0h",
                    c.tag, c.cause.name(), c.dut_pa, c.va))
      end
    end
  endfunction : check_xlate

  virtual function void report_phase(uvm_phase phase);
    `uvm_info(get_type_name(),
      $sformatf("SB summary: %0d checked, %0d match, %0d mismatch",
                num_checked, num_match, num_mismatch), UVM_LOW)
  endfunction : report_phase

endclass : mmu_scoreboard_base

`endif // MMU_SCOREBOARD_BASE_SV
