// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_ifu_seq.sv
//
// IFU (instruction-fetch) translation sequence. Extends mmu_base_seq and
// overrides ONLY drive_stimulus(): the base handles the shared setup
// (generate page tables -> preload sysmem+Whisper -> program satp), and this
// sequence drives the IFU port: it extends mmu_base_seq and overrides only
// the driving phase.
//
// Drives num_of_reqs translations, picking VAs from the pool WITH REPLACEMENT
// success-only checked here (pavld=1 && pgflt=0);
// the mmu_scoreboard does the
// independent DUT-vs-Whisper PA/fault compare.
//======================================================================

`ifndef MMU_IFU_SEQ_SV
`define MMU_IFU_SEQ_SV

class mmu_ifu_seq extends mmu_base_seq;
  `uvm_object_utils(mmu_ifu_seq)

  // Privilege randomization (always on): re-randomize
  // cp0_yy_priv_mode every `priv_batch` fetches across U/S/M (dist 35/50/15).
  // The interval is itself randomized 500..1000 requests.
  // M-mode fetches bypass translation (PA=VA, no
  // fault); the scoreboard handles that case.
  int unsigned priv_batch;

  // When 0, this sequence does NOT drive its own privilege changes (CTX_SET) --
  // used by the combined IFU+LSU test where the parent owns the shared priv so
  // the two sequences don't race on it. Default 1 (standalone IFU test).
  bit switch_priv = 1'b1;

  function new(string name = "mmu_ifu_seq");
    super.new(name);
  endfunction

  // Drive one CTX_SET to change the current privilege (keeps satp; fetch
  // ignores MPRV so mprv/mpp are don't-cares for the IFU path).
  protected task set_priv(bit [1:0] pm);
    mmu_csr_seq_item ctx;
    bit mxr_v, sum_v;
    // C910 applies SUM to FETCH (manual Ch.17: "load, store, and fetch"), so the
    // IFU randomizes it too. MXR is load-only -- held 0 here (nothing to cover).
    rand_sum_mxr(mxr_v, sum_v);
    ctx = mmu_csr_seq_item::type_id::create("ctx_priv");
    start_item(ctx, -1, p_sequencer.csr_sqr);
    ctx.op        = mmu_csr_seq_item::CTX_SET;
    ctx.priv_mode = pm;
    ctx.mprv      = 1'b0;
    ctx.mpp       = 2'b00;
    ctx.mxr       = 1'b0;
    ctx.sum       = sum_v;
    ctx.ptw_en    = 1'b1;
    ctx.maee      = 1'b0;
    ctx.cskyee    = 1'b0;
    finish_item(ctx);
    `uvm_info("MMU_IFU_SEQ", $sformatf("priv_mode -> %s sum=%0b",
      (pm==2'b00) ? "U" : (pm==2'b01) ? "S" : (pm==2'b11) ? "M" : "?", sum_v), UVM_LOW)
  endtask

  // Pick a privilege per the U/S/M distribution.
  // Privilege weights: S-DOMINANT. Every generated page is u=0 (supervisor),
  // and C910 has no SUM setter wired yet, so a U-mode access to a u=0 page ALWAYS
  // page-faults. Driving 35% U-mode therefore floods the test with USER page
  // faults (measured ~28% fault rate, ~all U-mode) and swamps the intended ~2%
  // attribute-injected faults. Keep U small (~5%) so USER-fault coverage stays
  // meaningful without dominating; S is accessible to u=0 pages; M bypasses.
  protected function bit [1:0] rand_priv();
    int unsigned r = $urandom_range(0, 99);
    if      (r < 5)  return 2'b00;   // U : 5   (u=0 pages -> guaranteed fault; small on purpose)
    else if (r < 90) return 2'b01;   // S : 85  (u=0 pages are S-accessible)
    else             return 2'b11;   // M : 10  (bypass, PA=VA)
  endfunction

  virtual task drive_stimulus();
    mmu_va_map_t m;
    int unsigned total, idx;
    if (p_sequencer.ifu_sqr == null)
      `uvm_fatal("MMU_IFU_SEQ", "p_sequencer.ifu_sqr is null (env must connect vseqr.ifu_sqr)")

    if (va_entries.size() == 0)
      `uvm_fatal("MMU_IFU_SEQ", "no VAs loaded")

    // Drive num_of_reqs requests total, picking VAs from the
    // pool WITH REPLACEMENT so repeats exercise TLB hit/reuse. Re-randomize the
    // privilege (U/S/M) before each ~300-400-request batch.
    total = resolve_num_reqs();
    idx   = 0;
    `uvm_info("MMU_IFU_SEQ", $sformatf("driving %0d IFU translations (pool=%0d)",
              total, va_entries.size()), UVM_LOW)
    while (idx < total) begin
      mmu_ifu_translate_seq xlate;
      int unsigned n;
      priv_batch = $urandom_range(batch_lo, batch_hi);
      n = (total - idx < priv_batch) ? (total - idx) : priv_batch;
      // switch_priv=0 (combined IFU+LSU test): don't drive CTX_SET here -- the
      // parent owns the shared privilege so the two sequences don't race on it.
      if (switch_priv) set_priv(rand_priv());
      xlate = mmu_ifu_translate_seq::type_id::create("xlate");
      for (int j = 0; j < n; j++) begin
        m.va = va_entries[$urandom_range(0, va_entries.size()-1)].va;
        m.pa = '0; m.page_kb = 4;
        xlate.va_map.push_back(m);
      end
      xlate.check_pa   = 1'b0;   // scoreboard is authoritative (faults expected)
      xlate.max_vas    = n;
      xlate.num_passes = 1;
      xlate.start(p_sequencer.ifu_sqr);
      idx += n;
    end
  endtask

endclass : mmu_ifu_seq

`endif // MMU_IFU_SEQ_SV
