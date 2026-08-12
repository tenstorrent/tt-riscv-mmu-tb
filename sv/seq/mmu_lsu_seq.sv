// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_lsu_seq.sv
//
// LSU (data load/store) translation sequence. Extends mmu_base_seq and
// overrides ONLY drive_stimulus(): the base handles shared setup (generate
// page tables -> preload sysmem+Whisper -> program satp), and this sequence
// drives the LSU port. Mirrors mmu_ifu_seq on the data side.
//
// Drives num_of_reqs translations, picking VAs from the pool WITH REPLACEMENT;
// success-only checked here (any response), with the mmu_scoreboard doing the
// independent DUT-vs-Whisper PA/fault compare (load=is_read, store=is_write).
//======================================================================
`ifndef MMU_LSU_SEQ_SV
`define MMU_LSU_SEQ_SV

class mmu_lsu_seq extends mmu_base_seq;
  `uvm_object_utils(mmu_lsu_seq)

  // Percent of accesses issued as stores (0 = loads only, Step 2 default).
  int unsigned store_pct = 0;

  // Batch length over which the privilege is held constant, then re-randomized
  // Randomized 500..1000 per batch below.
  int unsigned priv_batch;

  // When 0, this sequence does NOT drive its own privilege changes (CTX_SET) --
  // used by the combined IFU+LSU test where the parent owns the shared priv so
  // the two sequences don't race on it. Default 1 (standalone LSU test).
  bit switch_priv = 1'b1;

  function new(string name = "mmu_lsu_seq");
    super.new(name);
  endfunction

  // Drive one CTX_SET to set the privilege context. All three CSR fields are
  // randomized to valid values by the caller: priv_mode (U/S/M), mprv (0/1),
  // mpp (U/S/M). DATA accesses honor MPRV: the effective priv is (mprv?mpp:priv)
  // (ct_pmp_acc.v:107) -- so e.g. M-mode+mprv=1+mpp=S actually WALKS as
  // Supervisor (the M-mode-walk path). The scoreboard derives the same
  // effective priv, and mmu_if models it on the data/walk PMP ports.
  protected task set_priv(bit [1:0] pm, bit use_mprv, bit [1:0] pp,
                          bit mxr_v = 1'b0, bit sum_v = 1'b0);
    mmu_csr_seq_item ctx;
    ctx = mmu_csr_seq_item::type_id::create("ctx_priv");
    start_item(ctx, -1, p_sequencer.csr_sqr);
    ctx.op        = mmu_csr_seq_item::CTX_SET;
    ctx.priv_mode = pm;
    ctx.mprv      = use_mprv;
    ctx.mpp       = pp;
    ctx.mxr       = mxr_v;
    ctx.sum       = sum_v;
    ctx.ptw_en    = 1'b1;
    ctx.maee      = 1'b0;
    ctx.cskyee    = 1'b0;
    finish_item(ctx);
    `uvm_info("MMU_LSU_SEQ", $sformatf("priv_mode -> %s mprv=%0b mpp=%0d mxr=%0b sum=%0b",
      (pm==2'b00) ? "U" : (pm==2'b01) ? "S" : (pm==2'b11) ? "M" : "?", use_mprv, pp, mxr_v, sum_v), UVM_LOW)
  endtask

  // Privilege weights: S-DOMINANT. Pages are u=0 (supervisor) and SUM is not
  // wired, so U-mode (or mprv-effective U) on a u=0 page ALWAYS page-faults.
  // For LSU the effective priv is mprv?mpp:priv, and BOTH pm and pp come from
  // this function, so keeping U small here bounds effective-U faults to ~5%.
  protected function bit [1:0] rand_priv();
    int unsigned r = $urandom_range(0, 99);
    if      (r < 5)  return 2'b00;   // U : 5   (u=0 pages -> guaranteed fault; small on purpose)
    else if (r < 90) return 2'b01;   // S : 85  (u=0 pages are S-accessible)
    else             return 2'b11;   // M : 10  (bypass, PA=VA)
  endfunction

  virtual task drive_stimulus();
    mmu_va_map_t m;
    int unsigned total, idx;
    if (p_sequencer.lsu_sqr0 == null || p_sequencer.lsu_sqr1 == null)
      `uvm_fatal("MMU_LSU_SEQ", "p_sequencer.lsu_sqr0/1 is null (env must connect vseqr.lsu_sqr0/1)")

    if (va_entries.size() == 0)
      `uvm_fatal("MMU_LSU_SEQ", "no VAs loaded")

    // Drive num_of_reqs requests total, picking VAs from the
    // pool WITH REPLACEMENT so repeats exercise TLB hit/reuse.
    total = resolve_num_reqs();
    idx   = 0;
    `uvm_info("MMU_LSU_SEQ", $sformatf("driving %0d LSU translations (pool=%0d)",
              total, va_entries.size()), UVM_LOW)

    // Drive in privilege batches: re-randomize U/S/M before each batch, split
    // that batch's VAs across the two fast pipes (even->pipe0, odd->pipe1), and
    // run both pipes concurrently. Holding priv constant per batch keeps the
    // scoreboard's per-txn priv unambiguous while both pipes are in flight.
    while (idx < total) begin
      mmu_lsu_translate_seq x0, x1;
      int unsigned n, k;
      bit [1:0]    pm, pp;
      bit          mprv, mxr_v, sum_v;
      priv_batch = $urandom_range(batch_lo, batch_hi);
      n  = (total - idx < priv_batch) ? (total - idx) : priv_batch;
      // Randomize the full privilege context to valid values: priv U/S/M, mprv
      // 0/1, mpp U/S/M. Effective priv (mprv?mpp:priv) covers M-mode-walk etc.
      pm   = rand_priv();
      mprv = $urandom_range(0, 1);
      pp   = rand_priv();
      rand_sum_mxr(mxr_v, sum_v);   // SUM/MXR (default off; +MMUTB_EN_CSR_RAND)
      // switch_priv=0 (combined IFU+LSU test): the parent owns the shared
      // privilege, so this sequence must NOT drive CTX_SET (no race on the pin).
      if (switch_priv) set_priv(pm, mprv, pp, mxr_v, sum_v);

      x0 = mmu_lsu_translate_seq::type_id::create("x0");
      x1 = mmu_lsu_translate_seq::type_id::create("x1");
      for (int j = 0; j < n; j++) begin
        m.va = va_entries[$urandom_range(0, va_entries.size()-1)].va;
        m.pa = '0;  m.page_kb = 4;
        if (j % 2 == 0) x0.va_map.push_back(m);
        else            x1.va_map.push_back(m);
      end
      k = (n + 1) / 2;
      x0.max_vas = k;         x0.num_passes = 1;  x0.store_pct = store_pct;
      x1.max_vas = n - k;     x1.num_passes = 1;  x1.store_pct = store_pct;

      fork
        x0.start(p_sequencer.lsu_sqr0);
        x1.start(p_sequencer.lsu_sqr1);
      join

      if (x0.fail_cnt + x1.fail_cnt != 0)
        `uvm_error("MMU_LSU_SEQ",
          $sformatf("%0d LSU translations failed", x0.fail_cnt + x1.fail_cnt))
      idx += n;
    end

    // Restore a clean context (S-mode, mprv=0) so a leftover non-S priv or
    // mprv=1 can't leak into IFU stimulus that runs after/alongside this
    // sequence in a shared test (e.g. the combined IFU+LSU test).
    if (switch_priv) set_priv(2'b01, 1'b0, 2'b00);
  endtask

endclass : mmu_lsu_seq

`endif // MMU_LSU_SEQ_SV
