// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_ifu_lsu_seq.sv
//
// Combined IFU + LSU translation sequence. Extends
// mmu_base_seq: this sequence does the ONE-TIME shared setup (generate page
// tables -> preload sysmem+Whisper -> program satp) itself, then forks the
// IFU and LSU drive phases so both interfaces translate CONCURRENTLY against
// the same page tables / PMP config / satp.
//
// Privilege: the two sub-sequences run with switch_priv=0 (they do NOT drive
// their own CTX_SET), so they don't race on the shared privilege pin. This
// parent sets one fixed privilege (S) for the run. Coordinated mid-run
// privilege / satp switching lives in mmu_dynamic_satp_seq, which owns context
// changes via the CSR driver's wait_for_mmu_idle() gate.
//======================================================================
`ifndef MMU_IFU_LSU_SEQ_SV
`define MMU_IFU_LSU_SEQ_SV

class mmu_ifu_lsu_seq extends mmu_base_seq;
  `uvm_object_utils(mmu_ifu_lsu_seq)

  // Stores as a percent of LSU accesses (loads otherwise).
  int unsigned store_pct = 40;

  function new(string name = "mmu_ifu_lsu_seq");
    super.new(name);
  endfunction

  // Randomize the privilege context ONCE at the start, then hold it for the
  // whole run. Randomizing once is race-free (unlike mid-run switching, which
  // would need coordination between the two concurrent sub-seqs). priv U/S/M
  // (35/50/15), mprv 0/1, mpp U/S/M -- effective priv (mprv?mpp:priv) is what
  // data accesses use, so e.g. M-mode+mprv=1+mpp=S walks as Supervisor.
  protected task set_priv_rand();
    mmu_csr_seq_item ctx;
    bit [1:0] pm, pp;
    bit       mprv, mxr_v, sum_v;
    // S-DOMINANT (u=0 pages, no SUM => U-mode faults; keep U ~5%).
    int       r = $urandom_range(0, 99);
    pm   = (r < 5) ? 2'b00 : (r < 90) ? 2'b01 : 2'b11;   // U:5 S:85 M:10
    mprv = $urandom_range(0, 1);
    r    = $urandom_range(0, 99);
    pp   = (r < 5) ? 2'b00 : (r < 90) ? 2'b01 : 2'b11;
    rand_sum_mxr(mxr_v, sum_v);   // SUM/MXR (default off; +MMUTB_EN_CSR_RAND)
    ctx = mmu_csr_seq_item::type_id::create("ctx_priv");
    start_item(ctx, -1, p_sequencer.csr_sqr);
    ctx.op = mmu_csr_seq_item::CTX_SET; ctx.priv_mode = pm;
    ctx.mprv = mprv; ctx.mpp = pp; ctx.mxr = mxr_v; ctx.sum = sum_v;
    ctx.ptw_en = 1'b1; ctx.maee = 1'b0; ctx.cskyee = 1'b0;
    finish_item(ctx);
    `uvm_info("MMU_IFU_LSU_SEQ", $sformatf("initial priv=%s mprv=%0b mpp=%0d mxr=%0b sum=%0b",
      (pm==2'b00)?"U":(pm==2'b01)?"S":"M", mprv, pp, mxr_v, sum_v), UVM_LOW)
  endtask

  virtual task drive_stimulus();
    int unsigned total, done;
    // Drive in PRIVILEGE BATCHES like the standalone tests: the PARENT owns the
    // shared priv pin and re-randomizes U/S/M once per batch, then forks IFU+LSU
    // to each drive that batch CONCURRENTLY, and joins. Priv therefore changes
    // only at batch boundaries (both pipes drained at the join), so the two
    // sub-seqs never race on the pin and no access straddles a priv change.
    // This replaces the old single-priv-for-the-whole-run model (which, with an
    // unseeded SV RNG, got stuck on one priv -- typically U -> all faults).
    total = resolve_num_reqs();
    done  = 0;
    while (done < total) begin
      mmu_ifu_seq ifu;
      mmu_lsu_seq lsu;
      int unsigned n = $urandom_range(batch_lo, batch_hi);
      if (n > total - done) n = total - done;

      set_priv_rand();   // random U/S/M (+mprv/mpp) for THIS batch, on the shared pin

      ifu = mmu_ifu_seq::type_id::create("ifu");
      lsu = mmu_lsu_seq::type_id::create("lsu");
      // Sub-seqs: setup already done, do NOT drive priv (parent owns it), and
      // drive exactly this batch's request count with no internal priv batching.
      ifu.skip_setup = 1'b1;  ifu.switch_priv = 1'b0;  ifu.num_of_reqs = n;
      lsu.skip_setup = 1'b1;  lsu.switch_priv = 1'b0;  lsu.num_of_reqs = n;
      lsu.store_pct  = store_pct;
      ifu.batch_lo = n;  ifu.batch_hi = n;   // single internal batch of n
      lsu.batch_lo = n;  lsu.batch_hi = n;
      ifu.va_entries = va_entries;  ifu.satp_ppn = satp_ppn;  ifu.satp_mode = satp_mode;
      lsu.va_entries = va_entries;  lsu.satp_ppn = satp_ppn;  lsu.satp_mode = satp_mode;

      fork
        ifu.start(p_sequencer);
        lsu.start(p_sequencer);
      join

      done += n;
    end
  endtask

endclass : mmu_ifu_lsu_seq

`endif // MMU_IFU_LSU_SEQ_SV
