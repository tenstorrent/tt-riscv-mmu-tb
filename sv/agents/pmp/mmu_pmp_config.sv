// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_pmp_config.sv
//
// 16-entry PMP region model: config (mode/r/w/x/l/addr per entry) plus
// derived [lo,hi) bounds and a region matcher, matching ct_pmp_acc.v's
// behavior:
//   - a matched entry returns its raw {L,X,W,R} (the caller/MMU applies
//     the mach/lock rule, not this model);
//   - no match returns a priv-dependent default: 4'b0111 in M-mode
//     (cur_priv_mode==2'b11), else 4'h0 (ct_pmp_acc.v:256).
// match() takes an already-resolved effective privilege; callers apply the
// MPRV/MPP substitution for data accesses before calling in.
//
// Shared by the PMP responder, Whisper CSR programming (to_pmpcfg_pmpaddr),
// and the scoreboard.
//======================================================================

`ifndef MMU_PMP_CONFIG_SV
`define MMU_PMP_CONFIG_SV

class mmu_pmp_config extends uvm_object;
  `uvm_object_utils(mmu_pmp_config)

  // A-field encoding (NA4=2'b10 unused/unmodeled).
  typedef enum bit [1:0] { PMP_OFF = 2'b00, PMP_TOR = 2'b01, PMP_NAPOT = 2'b11 } pmp_mode_e;

  rand pmp_mode_e mode[16];
  rand bit        r[16], w[16], x[16], l[16];
  rand bit [27:0] addr[16];   // PPN (4 KB granule)

  // Derived by recompute()/post_randomize(): per-entry [lo,hi) PPN bounds.
  // 29 bits wide (not 28) so the EXCLUSIVE upper bound of a full-PPN-space
  // NAPOT region -- hi=2^28 -- is representable; a 28-bit hi would wrap to 0
  // (empty range). lo stays <2^28 but is widened to match for clean compares.
  bit [28:0] lo[16], hi[16];
  bit        vld[16];

  //--------------------------------------------------------------------
  // PT-window awareness. NOT rand -- the test sets these (from the
  // same PA bounds the page-table generator used, e.g. mmu_pt_config_gen's
  // MMAP_LO/HI) BEFORE calling randomize(), so c_window_align below confines
  // every entry's addr[] to real test memory (the driven VAs' PAs land
  // in this range) instead of a PPN nothing will ever touch. Defaults to the
  // full 28-bit PPN space, so callers that never set these (e.g. hand-built
  // configs that don't call randomize() on this class at all) are unaffected.
  bit [28:0] win_lo_ppn = 29'h0;
  bit [28:0] win_hi_ppn = 29'h1000_0000;   // 2^28 (exclusive)

  // Caps on a single entry's own span, so a randomized deny can't blanket
  // the whole PT window (which is what made the temporary +PMP_DENY_*
  // knobs collide with the page-table walker's own PTE-fetch PMP check).
  // NAPOT_SIZE_CAP_BIT forces that addr
  // bit to 0, which upper-bounds the trailing-ones run recompute() reads out
  // of addr (see its comment), capping NAPOT size to <= 2^(CAP_BIT+1) PPNs.
  // TOR_MAX_SPAN directly bounds a TOR entry's [prev.addr, addr) width.
  localparam int          NAPOT_SIZE_CAP_BIT = 7;          // <= 256 PPNs (1 MB)
  localparam bit [27:0]   TOR_MAX_SPAN       = 28'd256;    // <= 256 PPNs (1 MB)

  // ---- Randomization constraints -------------------------------------
  // Explicit (if redundant with the enum's own domain) so a future NA4 value
  // added to pmp_mode_e wouldn't silently start showing up here.
  constraint c_valid_mode {
    foreach (mode[i]) mode[i] inside {PMP_OFF, PMP_TOR, PMP_NAPOT};
  }

  // Every entry's addr[] lands inside the live PT's PA window (in PPN units)
  // so a rand-enabled entry actually has a chance of covering real,
  // driven-VA-backed memory. Applies to ALL 16 entries (not just the
  // enabled ones): a TOR entry's OWN lower bound is the PREVIOUS entry's raw
  // addr[] regardless of that entry's mode (recompute()), so an OFF entry's
  // addr must be window-bound too or it could hand a following TOR entry a
  // bogus (out-of-window or empty) span.
  constraint c_window_align {
    foreach (addr[i]) {
      {1'b0, addr[i]} >= win_lo_ppn;
      {1'b0, addr[i]} <  win_hi_ppn;
    }
  }

  // Rare "large region" opt-out of the size caps (~2%): most entries stay
  // small/diverse, but occasionally a full-range NAPOT/TOR region (up to the
  // whole PT window) is exercised so the decode + walk-PMP path sees big spans
  // too. When big_region[i]=1 the caps below are lifted for that entry.
  rand bit big_region[16];
  constraint c_big_region {
    foreach (big_region[i]) big_region[i] dist { 1'b0 := 98, 1'b1 := 2 };
  }

  // Bound NAPOT region size (see NAPOT_SIZE_CAP_BIT comment above) UNLESS this
  // entry is a rare big_region (then any naturally-aligned NAPOT size is legal).
  constraint c_napot_size_cap {
    foreach (addr[i])
      (mode[i] == PMP_NAPOT && !big_region[i]) -> addr[i][NAPOT_SIZE_CAP_BIT] == 1'b0;
  }

  // Bound TOR span, and require it non-empty (addr[i] > addr[i-1]).
  // Entry 0 is excluded (c_mode_mix below forbids mode[0]==TOR): recompute()
  // hardcodes entry 0's TOR lower bound to literal PPN 0 (not the previous
  // entry's addr -- there IS no entry -1), so its span is [0, addr[0]) --
  // at least win_lo_ppn wide by c_window_align, ignoring any cap here.
  // (Found empirically, PT_SEED=7: an uncapped entry 0 TOR denied ~145M PPNs
  // -- most of the window -- for W, colliding with a real store-walk's PTE.)
  // A rare big_region entry lifts the span cap (still non-empty, window-bound).
  constraint c_tor_span_cap {
    foreach (addr[i]) if (i > 0) (mode[i] == PMP_TOR) -> (addr[i] > addr[i-1]) &&
      (big_region[i] || (addr[i] - addr[i-1] <= TOR_MAX_SPAN));
  }

  // Known Whisper-side edge (deferred): a TOR entry immediately
  // after a NAPOT entry picks up that entry's NAPOT mask bits as its lower
  // bound in Whisper. Constrained away here rather than fixed.
  constraint c_no_tor_after_napot {
    foreach (mode[i]) if (i > 0) (mode[i-1] == PMP_NAPOT) -> mode[i] != PMP_TOR;
  }

  // Deny/allow/lock mix: independent per-bit weighting gives a spread of
  // fully-open, fully-closed, and partial-permission entries, plus a
  // minority locked (so an M-mode-locked deny shows up without every entry
  // being one).
  //
  // r[]/w[]/x[] are all randomized closed. R used to be pinned to 1 to avoid a
  // divergence: Whisper's own page-walk model checks READ on every PTE it
  // fetches (any access type), while the DUT (ct_mmu_ptw.v ptw_pmp_deny) checks
  // X/R/W by the ORIGINATING access type. That divergence is now moot because
  // the scoreboard (a) neutralizes Whisper's PMP (write_pmp programs it
  // permissive, so Whisper never PMP-faults a walk) and (b) owns ALL PMP: an
  // SV walker checks each PTE read with the C910 per-access-type rule
  // (ptw_pmp_deny), and pmp_deny() checks the final PA. So a randomized R=0 (or
  // W=0/X=0) region may now freely OVERLAP the page tables; the walk-PMP
  // predictor scores it against the DUT.
  // Per-region "fully permissive" draw, 95/5: 95% of regions grant RWX
  // so a walk crossing them succeeds, and the remaining 5% take the randomized
  // permission mix below -- which may legitimately abort a page-table walk with
  // an access fault. Drawn per REGION, not per bit: three independent 75/25
  // bits would leave only 0.75^3 = 42% of regions fully open, far too many
  // walk aborts once these regions are allowed to overlap the page tables.
  rand bit full_perms[16];

  // Master override: force every region fully permissive.
  // For feature-targeted tests -- basic IFU/LSU -- that would otherwise abort on
  // their first walk and never reach the behaviour they exist to exercise.
  // Not rand: the caller sets it before randomize().
  bit no_excp = 1'b0;

  constraint c_perm_lock_mix {
    foreach (full_perms[i]) full_perms[i] dist { 1'b1 := 95, 1'b0 := 5 };
    foreach (r[i]) if (no_excp || full_perms[i]) r[i] == 1'b1;
                   else                          r[i] dist { 1'b1 := 75, 1'b0 := 25 };
    foreach (w[i]) if (no_excp || full_perms[i]) w[i] == 1'b1;
                   else                          w[i] dist { 1'b1 := 75, 1'b0 := 25 };
    foreach (x[i]) if (no_excp || full_perms[i]) x[i] == 1'b1;
                   else                          x[i] dist { 1'b1 := 75, 1'b0 := 25 };
    foreach (l[i]) if (no_excp) l[i] == 1'b0;
                   else         l[i] dist { 1'b1 := 15, 1'b0 := 85 };
  }

  // Mode mix: a MINORITY of entries OFF, the rest split TOR/NAPOT -- a
  // subset of entries, not every entry active.
  // Entry 0 excludes TOR (see c_tor_span_cap comment -- its span is
  // uncappable, [0, addr[0]), by recompute()'s own hardcoded lower bound).
  constraint c_mode_mix {
    mode[0] inside {PMP_OFF, PMP_NAPOT};
    foreach (mode[i]) if (i > 0) mode[i] dist { PMP_OFF := 35, PMP_TOR := 25, PMP_NAPOT := 40 };
  }

  // Baseline PERMIT over the whole window, at the LAST index so every randomized
  // deny above still wins where it matches. The randomized entries are capped at
  // 256 PPNs in a 2^28-PPN window, so without this almost nothing matches and the
  // S/U no-match rule denies ~everything (measured: 0 translations in 2000).
  // Skipped 2% of runs so the no-match fault is still covered; permissions are
  // randomized 5% of runs. Clear catchall_en to disable it entirely.
  //
  // These two are NOT rand: as rand guards on the implication below the solver
  // skews to the unconstrained branch and the catch-all silently disappears.
  localparam int CATCHALL_IDX = 15;
  bit catchall_en = 1'b1;
  bit catchall_present;
  bit catchall_full_perm;

  function void pre_randomize();
    catchall_present   = ($urandom_range(0, 99) >= 2);
    catchall_full_perm = ($urandom_range(0, 99) >= 5);
  endfunction


  // ANCHORED entries: pinned to PPNs the test actually accesses (the caller
  // supplies them from the generated leaf PTEs). Random addr[] never lands on
  // live traffic, so these are the only entries that produce real deny coverage.
  // Permissions are assigned, not randomized -- a random mix comes out
  // permissive too often to deny anything. R/W/X-deny is cycled across the
  // anchors, every 4th left fully permissive.
  localparam int NUM_ANCHORS = 4;
  bit            anchor_en = 1'b0;         // set by the caller with anchors[]
  bit [27:0]     anchors[NUM_ANCHORS];


  function new(string name = "mmu_pmp_config");
    super.new(name);
  endfunction

  // Entries 1..NUM_ANCHORS and the catch-all are ASSIGNED here rather than
  // constrained: they are fully determined, and expressing them as constraints
  // over pinned addr[] values is more than some solvers will take (Verilator
  // fails to solve it at all).
  function void post_randomize();
    if (anchor_en)
      foreach (anchors[j]) begin
        mode[j+1] = PMP_NAPOT;
        addr[j+1] = anchors[j];
        l[j+1]    = 1'b0;
        r[j+1]    = ((j % 4) != 0);   // j%4==0 -> deny loads
        w[j+1]    = ((j % 4) != 1);   // j%4==1 -> deny stores
        x[j+1]    = ((j % 4) != 2);   // j%4==2 -> deny fetches
      end
    if (catchall_en && catchall_present) begin
      mode[CATCHALL_IDX] = PMP_NAPOT;
      addr[CATCHALL_IDX] = 28'hFFFFFFF;   // -> lo=0, hi=2^28
      l[CATCHALL_IDX]    = 1'b0;
      if (catchall_full_perm) begin      // else keep the randomized r/w/x
        r[CATCHALL_IDX] = 1'b1; w[CATCHALL_IDX] = 1'b1; x[CATCHALL_IDX] = 1'b1;
      end
    end
    recompute();
  endfunction

  // Derive vld[]/lo[]/hi[] from mode[]/addr[] (ct_pmp_comp_hit.v equivalent).
  function void recompute();
    for (int i = 0; i < 16; i++) begin
      vld[i] = (mode[i] != PMP_OFF);
      if (mode[i] == PMP_NAPOT) begin           // lowest-0-bit of addr sets size
        bit [27:0] m = addr[i] ^ (addr[i] + 1);  // ...0111 mask
        lo[i] = addr[i] & ~m; hi[i] = lo[i] + m + 1;
      end else if (mode[i] == PMP_TOR) begin    // [prev.addr, addr)
        lo[i] = (i == 0) ? 28'h0 : addr[i-1]; hi[i] = addr[i];
      end
    end
  endfunction

  // Lowest-numbered valid entry with ppn inside [lo,hi) -> raw {L,X,W,R}.
  // No match: priv-dependent default (ct_pmp_acc.v:256), NOT filtered by
  // lock/mach here -- that rule belongs to the MMU responder, not this model.
  function bit [3:0] match(bit [27:0] ppn, bit [1:0] priv);
    for (int i = 0; i < 16; i++)
      if (vld[i] && ppn >= lo[i] && ppn < hi[i]) return {l[i], x[i], w[i], r[i]};
    return (priv == 2'b11) ? 4'b0111 : 4'h0;
  endfunction

  // Pack into pmpcfgN (2 x 64b, entries 0-7 / 8-15) and pmpaddrN (16 x 64b),
  // both keyed by entry index (values are PPN; the shift into CSR[37:9] happens downstream, not here).
  function void to_pmpcfg_pmpaddr(output longint unsigned pmpcfg[2], output longint unsigned pmpaddr[16]);
    longint unsigned cfg_byte_ext;
    pmpcfg[0] = 64'h0; pmpcfg[1] = 64'h0;
    for (int i = 0; i < 16; i++) begin
      byte unsigned cfg_byte = {l[i], 2'b0, mode[i], x[i], w[i], r[i]};
      cfg_byte_ext = cfg_byte;   // zero-extend into the 64b cfg register
      pmpcfg[i/8] |= (cfg_byte_ext << (8 * (i % 8)));
      if (mode[i] == PMP_NAPOT) begin
        bit [27:0] m = addr[i] ^ (addr[i] + 1);   // trailing-ones size mask
        pmpaddr[i] = addr[i] | m;
      end else begin
        pmpaddr[i] = addr[i];  // TOR/OFF: raw PPN
      end
    end
  endfunction

  // No-regression default: 1 NAPOT entry covering all PA, R=W=X=1, L=0.
  function void set_all_permissive();
    mode = '{default: PMP_OFF};
    r    = '{default: 1'b0};
    w    = '{default: 1'b0};
    x    = '{default: 1'b0};
    l    = '{default: 1'b0};
    addr = '{default: 28'h0};
    mode[0] = PMP_NAPOT;
    // Full-space NAPOT: addr=all-1s -> mask m=2^28-1, lo=0, hi=2^28. Because
    // hi[] is 29 bits (see decl) this top bound is representable, so the single
    // entry truly covers PPN [0, 2^28) = the whole test PA range, R=W=X, L=0.
    addr[0] = 28'hFFF_FFFF;
    r[0] = 1'b1; w[0] = 1'b1; x[0] = 1'b1; l[0] = 1'b0;
    recompute();
  endfunction

endclass : mmu_pmp_config

`endif // MMU_PMP_CONFIG_SV
