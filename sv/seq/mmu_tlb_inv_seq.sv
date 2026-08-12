// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_tlb_inv_seq.sv
//
// TLB-invalidation virtual sequence -- INVALIDATIONS ONLY.
//
// This sequence drives no traffic. It is meant to run CONCURRENTLY with the
// IFU/LSU stimulus sequences, which mmu_tlb_inv_test forks in parallel.
// Concurrency matters for two reasons:
//   * the TLBs stay POPULATED, so each flush has live entries to verify -- a
//     warm-once-then-flush-repeatedly structure empties the TLBs on the first
//     INV_ALL and every later check becomes vacuous; and
//   * flushes land while translations are in flight, which is the harder and
//     more realistic case than flushing a drained pipe.
//
// Invalidations are spaced by a randomized delay
// so traffic can refill between flushes, and the loop bounds itself to the
// traffic lifetime -- "invalidation without active traffic is not meaningful"
//
// The mmu_invalidation_checker (env) backdoor-reads the TLBs after each done
// pulse, asserts the flush semantics, and reports the live-entry count so a
// vacuous run cannot pass silently.
//======================================================================
`ifndef MMU_TLB_INV_SEQ_SV
`define MMU_TLB_INV_SEQ_SV

class mmu_tlb_inv_seq extends mmu_base_seq;
  `uvm_object_utils(mmu_tlb_inv_seq)

  int unsigned num_inval;   // invalidation requests (resolved below)

  // Set by mmu_tlb_inv_test around the forked traffic threads. Static so the
  // test can flip it without holding a handle to this sequence -- our stand-in
  // so the invalidation loop knows when the traffic sequences are still live.
  // Traffic has its OWN fixed budget and never waits on this sequence; it is the
  // invalidation stream that yields when traffic ends. num_inval is therefore a
  // CEILING, not a guarantee -- a seed that draws many long gaps can stop early,
  // which drive_stimulus() warns about. Sizing traffic (mmu_tlb_inv_test's
  // traffic_reqs) is the only faithful way to raise the achievable count.
  static bit traffic_active = 1'b0;

  // Warn if a run issues fewer than this (the low end of resolve_num_inval()).
  localparam int unsigned UNDERSHOOT_FLOOR = 50;

  function new(string name = "mmu_tlb_inv_seq");
    super.new(name);
  endfunction

  // Number of invalidations per run. Deliberately far below the old 200-300:
  // each one now waits a weighted gap (~13.7us average) so concurrent
  // traffic can refill the TLBs, and the run is bounded by the traffic lifetime.
  // 30-50 flushes against a POPULATED TLB is much stronger coverage than 300
  // against an empty one. Traffic is sized in mmu_tlb_inv_test to outlive this.
  // Override with +MMU_NUM_INVAL=<n>.
  protected function int unsigned resolve_num_inval();
    int unsigned v;
    if ($value$plusargs("MMU_NUM_INVAL=%d", v)) return v;
    return $urandom_range(50, 150);
  endfunction

  // Gap before each invalidation, in CPU clocks (10ns period). Re-randomized
  // every iteration so the concurrent traffic gets a varied window to refill the
  // TLBs. Bounded to 300-1500 cycles (3-15us): the floor guarantees enough time
  // for several 3-level page-table walks to repopulate entries, and the ceiling
  // keeps the run short enough that the full 50-150 invalidations fit inside the
  // traffic budget. Weight SHAPE follows the delay_cycles profile
  // (2/7/40/28/23%, mass in the middle), compressed into this range.
  int unsigned gap_cycles;

  // NOTE: written as a procedural weighted pick rather than a `rand` + `dist`
  // constraint. A dist constraint here would be the idiomatic form, but
  // the constrained-random support in Verilator crashes the whole simulation at
  // elaboration on it -- the same class of solver limitation that made an
  // inline enum-cast constraint produce out-of-range values earlier.
  // Revisit once the Verilator randomization support matures.
  //
  // NOTE: do not start a comment with the word "Verilator" -- its lexer treats
  // a comment whose first word is "verilator" (any case) as a lint pragma, so
  // prose like "Verilator's ..." fails with %Error-BADVLTPRAGMA.
  protected function int unsigned pick_gap_cycles();
    int unsigned r = $urandom_range(0, 99);
    if      (r <  2) return $urandom_range( 300,  400);   //  2% minimum
    else if (r <  9) return $urandom_range( 401,  600);   //  7% small
    else if (r < 49) return $urandom_range( 601,  900);   // 40% medium
    else if (r < 77) return $urandom_range( 901, 1200);   // 28% high
    else             return $urandom_range(1201, 1500);   // 23% long
  endfunction

  //--------------------------------------------------------------------
  // Invalidation stream. Drives NO traffic -- mmu_tlb_inv_test forks the IFU/LSU
  // sequences alongside this one. Each iteration waits a randomized gap (so the
  // concurrent traffic refills the TLBs), then issues one invalidation. The loop
  // stops early once traffic ends, since flushing an idle/empty MMU proves
  // nothing -- the loop is bounded by the traffic lifetime.
  //--------------------------------------------------------------------
  virtual task drive_stimulus();
    int unsigned issued = 0;

    if (p_sequencer.inv_sqr == null)
      `uvm_fatal("MMU_TLB_INV_SEQ", "inv_sqr is null (env must connect vseqr.inv_sqr)")
    num_inval = resolve_num_inval();
    `uvm_info("MMU_TLB_INV_SEQ", $sformatf(
      "issuing up to %0d invalidations alongside IFU/LSU traffic", num_inval), UVM_LOW)

    for (int i = 0; i < num_inval; i++) begin
      // Let the concurrent traffic refill the TLBs between flushes.
      gap_cycles = pick_gap_cycles();
      #(gap_cycles * 10ns);

      // Bound to the traffic lifetime: once the IFU/LSU sequences are done the
      // TLBs stop being refilled and further flushes are vacuous.
      if (!traffic_active) begin
        `uvm_info("MMU_TLB_INV_SEQ", $sformatf(
          "traffic complete - stopping invalidations after %0d/%0d", i, num_inval), UVM_LOW)
        break;
      end

      drive_one_inval(i);
      issued++;
    end
    `uvm_info("MMU_TLB_INV_SEQ", $sformatf("issued %0d of %0d invalidations",
              issued, num_inval), UVM_LOW)
    // num_inval is a ceiling bounded by the traffic lifetime (traffic never waits
    // on us). A seed drawing many long gaps can
    // undershoot; flag it so a thin run is visible rather than silent.
    if (issued < UNDERSHOOT_FLOOR)
      `uvm_warning("MMU_TLB_INV_SEQ", $sformatf(
        "only %0d invalidations issued (< %0d) - traffic ended first; raise +MMU_INV_TRAFFIC_REQS to fit more",
        issued, UNDERSHOOT_FLOOR))
  endtask

  //--------------------------------------------------------------------
  // Issue one invalidation on inv_sqr. VPN/ASID are drawn from the live pool so
  // VA/ASID-scoped variants can actually hit. The first 5 are forced to each
  // kind so every variant is covered even on a short run.
  //--------------------------------------------------------------------
  protected task drive_one_inval(int i);
    mmu_tlb_inv_seq_item it = mmu_tlb_inv_seq_item::type_id::create("inv");
    bit [26:0] pick_vpn = (va_entries.size() > 0)
      ? va_entries[$urandom_range(0, va_entries.size()-1)].va[38:12] : '0;
    start_item(it, -1, p_sequencer.inv_sqr);
    if (!it.randomize() with { vpn == pick_vpn; asid == gen_asid; })
      `uvm_error("MMU_TLB_INV_SEQ", "inv item randomize failed")
    // Set kind by ASSIGNMENT, not constraint: a cast-to-enum in an inline
    // constraint solved to an out-of-range kind on some solvers, leaving the
    // driver with no strobe -> no done -> watchdog timeout.
    if (i < 5) it.kind = mmu_inv_kind_e'(i);
    finish_item(it);
  endtask

endclass : mmu_tlb_inv_seq

`endif // MMU_TLB_INV_SEQ_SV
