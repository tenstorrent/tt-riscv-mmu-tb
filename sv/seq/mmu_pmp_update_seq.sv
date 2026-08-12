// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_pmp_update_seq.sv
//
// Mid-run PMP reprogramming. Builds a FRESH, independently
// randomized mmu_pmp_config using the same generation path as the base
// flow (mmu_pmp_config's window/size/mode constraints), reapplies the
// walker-safety PTE-avoidance pass, then
// pushes it through the PMP config-manager sequencer exactly like
// mmu_pmp_apply_seq (mmu_pmp_seq.sv): driver rewrites vif.pmp_cfg (the DUT's
// comb responder resyncs instantly) -> monitor republishes -> mmu_scoreboard
// ::write_pmp() reprograms Whisper (define_pmp_regs + mmr_write) and cur_pmp
// (the TB's PMP predictor). Callable any number of times mid-run -- each
// call is a fresh, independent reprogramming, not a delta on the previous
// config.
//
// Optional directed "flip" entry (forced into entry 0, which mmu_pmp_config
// ::match() always checks first): lets a caller pin ONE specific PPN to a
// known permission under this update, so a before/after check at that PPN is
// deterministic regardless of what the random draw did there. Left off
// (do_flip=0), entry 0 is just whatever c_mode_mix randomized.
//======================================================================

`ifndef MMU_PMP_UPDATE_SEQ_SV
`define MMU_PMP_UPDATE_SEQ_SV

class mmu_pmp_update_seq extends uvm_sequence #(mmu_pmp_seq_item);
  `uvm_object_utils(mmu_pmp_update_seq)

  // Inputs (set before start()) -- mirrors what the base flow sets on a
  // fresh mmu_pmp_config before randomize().
  bit [28:0] win_lo_ppn = 29'h0;
  bit [28:0] win_hi_ppn = 29'h1000_0000;
  int        rand_seed  = 1;

  // PTE-page PPNs (walker-safety invariant):
  // every deny region -- random or the directed flip below -- must stay
  // clear of these, or a cold walk's own PTE fetch could hit an unmodeled
  // walker-PMP deny.
  bit [27:0] pte_ppns[$];

  // Optional directed flip entry (entry 0).
  bit        do_flip;
  bit [27:0] flip_ppn;      // its containing 16-PPN NAPOT block is forced
  bit        flip_r = 1'b1, flip_w = 1'b1, flip_x = 1'b1, flip_l = 1'b0;

  // Output: the config actually applied. Caller may inspect (e.g. cfg.match())
  // for logging; do not mutate after start() returns.
  mmu_pmp_config cfg;

  function new(string name = "mmu_pmp_update_seq");
    super.new(name);
  endfunction

  protected function bit region_has_pte(bit [28:0] lo, bit [28:0] hi);
    foreach (pte_ppns[k])
      if ({1'b0, pte_ppns[k]} >= lo && {1'b0, pte_ppns[k]} < hi) return 1'b1;
    return 1'b0;
  endfunction

  task body();
    cfg = mmu_pmp_config::type_id::create("cfg_update");
    cfg.win_lo_ppn = win_lo_ppn;
    cfg.win_hi_ppn = win_hi_ppn;
    cfg.srandom(rand_seed);
    if (!cfg.randomize())
      `uvm_fatal("PMP_UPDATE", "mmu_pmp_config randomize() failed")

    // NOTE: no PTE-page neutralization here. This used to force w/x open on any
    // region overlapping a page table, which made the mid-run path inconsistent
    // with the base flow -- mmu_pmp_config deliberately allows a randomized
    // deny to overlap the page tables ("the walk-PMP predictor scores it against
    // the DUT"), and the scoreboard owns all PMP. The neutralization also no
    // longer did what its comment claimed: it relied on r[] being pinned open,
    // a pin that was since removed, so it blocked fetch/store-driven walk denies
    // (X/W) while still permitting load-driven ones (R). Region permissions are
    // now governed solely by mmu_pmp_config's 95/5 full_perms draw, with no_excp
    // available to force a clean run.

    // Walker-safety pass 2: a full-window permissive BACKGROUND at [14]/[15],
    // mirroring the base flow's config layout. Without this, every
    // in-window PPN NOT covered by one of the (few, small) random entries
    // above falls through to the S/U "no match" default of DENY
    // (mmu_pmp_config::match() / ct_pmp_acc.v:256) -- silently, since it is
    // not an explicit entry pass 1 can neutralize. That includes most PTE
    // pages (a 16-entry random draw covers only a small fraction of a
    // 28-bit-PPN window). Empirically: without this background, a cold
    // S-mode LSU walk whose PTE fell in the implicit no-match gap got a
    // duTLB access-fault deny on the PTE fetch that the driver's watchdog
    // then timed out on (no response) rather than a clean fault -- forcing
    // [14]/[15] closes the gap so every PPN matches at least this entry.
    cfg.mode[14] = mmu_pmp_config::PMP_OFF;   cfg.addr[14] = win_lo_ppn[27:0];
    cfg.mode[15] = mmu_pmp_config::PMP_TOR;   cfg.addr[15] = 28'hFFF_FFFF;
    cfg.r[15] = 1'b1; cfg.w[15] = 1'b1; cfg.x[15] = 1'b1; cfg.l[15] = 1'b0;

    // Directed flip: forced LAST, at index 0, which match() always checks
    // first -- so it deterministically governs flip_ppn regardless of what
    // any random entry (or the background above) drew there.
    if (do_flip) begin
      cfg.mode[0] = mmu_pmp_config::PMP_NAPOT;
      cfg.addr[0] = ((flip_ppn >> 4) << 4) | 28'h7;   // 3 trailing ones -> 16-PPN block
      cfg.r[0] = flip_r; cfg.w[0] = flip_w; cfg.x[0] = flip_x; cfg.l[0] = flip_l;
    end

    cfg.recompute();   // picks up all manual overrides above (14/15, and 0 if do_flip)

    if (do_flip && region_has_pte(cfg.lo[0], cfg.hi[0]))
      `uvm_fatal("PMP_UPDATE", $sformatf(
        "flip target ppn=0x%0h's 16-PPN block overlaps a PTE page -- caller must pick a PTE-free PPN",
        flip_ppn))

    req = mmu_pmp_seq_item::type_id::create("req");
    start_item(req);
    req.cfg = cfg;
    finish_item(req);
  endtask

endclass : mmu_pmp_update_seq

`endif // MMU_PMP_UPDATE_SEQ_SV
