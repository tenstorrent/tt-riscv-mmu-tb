// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_c910_pma_pmp.sv
//
// C910 PMA (sysmap) + PMP fault predictor.
//
// Whisper models neither C910's sysmap nor C910's PMP walk semantics, so the
// scoreboard cannot ask the reference model whether an access should take an
// ACCESS fault -- it has to predict that itself. This class is that predictor,
// split out from mmu_scoreboard so the C910-specific part is separable from the
// generic DUT-vs-reference comparison.
//
// Everything here mirrors DUT RTL directly and is C910-specific by definition:
//   sysmap_so()     - ct_mmu_sysmap / sysmap.h static PA region table
//   pmp_deny()      - ct_mmu_iutlb.v / ct_mmu_dutlb_read.v fault equations
//   walk_pmp_deny() - ct_mmu_ptw.v ptw_pmp_deny per-PTE-fetch check
//
// Whisper's own PMP is deliberately left unprogrammed (see mmu_scoreboard
// write_pmp()), so this class is the SOLE PMP authority for the testbench.
//======================================================================

`ifndef MMU_C910_PMA_PMP_SV
`define MMU_C910_PMA_PMP_SV

class mmu_c910_pma_pmp extends uvm_object;
  `uvm_object_utils(mmu_c910_pma_pmp)

  // Last PMP config observed, cloned by the scoreboard's write_pmp().
  mmu_pmp_config cur_pmp;

  // Walk context for the per-PTE-fetch check: shared DUT/TB physical memory
  // plus the satp root. Refreshed by the scoreboard, which owns the config_db
  // lookups (its own Sv39 walker needs the same values).
  mmu_sysmem mem;
  bit [27:0] satp_root_ppn;
  bit        satp_sv39;

  function new(string name = "mmu_c910_pma_pmp");
    super.new(name);
  endfunction

  function void set_pmp(mmu_pmp_config cfg);
    cur_pmp = cfg;
  endfunction

  function void refresh(mmu_sysmem m, bit [27:0] root_ppn, bit sv39);
    mem           = m;
    satp_root_ppn = root_ppn;
    satp_sv39     = sv39;
  endfunction

  // C910 sysmap (PMA) strong-order predictor. C910 classifies every PHYSICAL
  // address into 8 static regions (ct_mmu_sysmap, sysmap.h) with a 5-bit flag
  // {So,C,B,Sh,Sec}. An instruction fetch from a strong-ordered (device) region
  // raises an ACCESS fault (mmu_ifu_deny), independent of translation. Whisper
  // does not model C910's sysmap, so we predict the So attribute here.
  //
  // Region n covers [base_{n-1}, base_n) on the PPN (PA>>12); base_0 lower = 0.
  // Returns 1 if the PA's region is strong-ordered (So bit set).
  //   regions (PPN top-bound : flag[4:0]={So,C,B,Sh,Sec}):
  //     0x01000:01111  0x02000:10000  0x0d0000:10000  0x0effff:01101
  //     0x0fffff:01111  0x4000000:01111 0x5000000:10000 0xfffffff:01111
  //     default (>= 0xfffffff): 10011  (So=1)
  // Takes the 28-bit physical page number (PA[39:12]) — the same field the DUT
  // sysmap compares. Do NOT pass the full 64-bit (sign-extended) VA.
  function bit sysmap_so(bit [27:0] ppn);
    if      (ppn <  28'h01000)   return 1'b0;  // region0 01111  So=0
    else if (ppn <  28'h02000)   return 1'b1;  // region1 10000  So=1
    else if (ppn <  28'h0d0000)  return 1'b1;  // region2 10000  So=1
    else if (ppn <  28'h0effff)  return 1'b0;  // region3 01101  So=0
    else if (ppn <  28'h0fffff)  return 1'b0;  // region4 01111  So=0
    else if (ppn <  28'h4000000) return 1'b0;  // region5 01111  So=0
    else if (ppn <  28'h5000000) return 1'b1;  // region6 10000  So=1
    else if (ppn <  28'hfffffff) return 1'b0;  // region7 01111  So=0
    else                         return 1'b1;  // default 10011  So=1
  endfunction

  // PMP-deny predictor. Mirrors the DUT's own fault equations:
  //   IFU (ct_mmu_iutlb.v:611-614):       mmu_ifu_deny |= !flg[2] && !(mach && !flg[3])
  //   LSU (ct_mmu_dutlb_read.v:491-497):  access_fault |=
  //        !flg[0] && (pmp_read_type || dutlb_ori_read_x) && !(mach && !flg[3])   // R
  //     || !flg[1] && !pmp_read_type              && !(mach && !flg[3])           // W
  // flg = {L,X,W,R} is the matched entry's raw bits (mmu_pmp_config::match(),
  // priv-dependent default on no-match, same as ct_pmp_acc.v:256); "gate" is
  // the shared "!(M-mode && unlocked)" term -- an M-mode access bypasses an
  // UNLOCKED entry, but a LOCKED entry (or any non-M priv) is still checked.
  //
  // PIPE ASYMMETRY (the reason for is_pipe0): dutlb_ori_read_x is HARDWIRED
  // per pipe -- dutlb_ori_read0=1'b1 (ct_mmu_dutlb.v:1370),
  // dutlb_ori_read1=1'b0 (:1500). So pipe0's R-check "(pmp_read_type ||
  // dutlb_ori_read0)" is ALWAYS 1 -- pipe0 checks R on EVERY access, incl. a
  // STORE (where it also checks W, since pmp_read_type=dutlb_read_type0=
  // !st_inst=0 -> !pmp_read_type=1). Pipe1 checks R only when pmp_read_type=1
  // (a load). Hence read_active = is_read || is_pipe0. IFU only ever checks X
  // (is_read=is_pipe0=0 there, so read_active is a don't-care). Whisper has no
  // execute query and does not model pipe0's always-R quirk, so this predictor
  // is the sole source for execute-vs-PMP and the pipe0 store-R deny.
  function bit pmp_deny(bit [27:0] ppn, bit [1:0] priv,
                        bit is_read, bit is_write, bit is_execute,
                        bit is_pipe0);
    // No cfg yet -> permit exactly as the RTL no-match default (ct_pmp_acc.v:256).
    bit [3:0] f = (cur_pmp == null) ? ((priv == 2'b11) ? 4'b0111 : 4'h0)
                                    : cur_pmp.match(ppn, priv);  // {L,X,W,R}
    bit       gate        = !(priv == 2'b11 && !f[3]);  // M-mode bypasses only an UNLOCKED entry
    bit       read_active = is_read || is_pipe0;        // pipe0 hardwires dutlb_ori_read=1 -> always R
    return (is_execute && !f[2] && gate) || (read_active && !f[0] && gate) || (is_write && !f[1] && gate);
  endfunction : pmp_deny

  // Per-PTE-read PMP for a page-table walk, modelling ct_mmu_ptw.v ptw_pmp_deny:
  // the DUT checks PMP on EACH PTE fetch address by the ORIGINATING access type
  // (fetch->X, load->R, store->W) plus the M-mode lock gate. We re-walk Sv39
  // from satp_root_ppn, reading each level's PTE from the shared memory, and
  // return 1 if any fetched PTE's region denies that access type. A PTE-fetch
  // access fault aborts the walk before the leaf, so we stop at the first
  // denied level (and also at the leaf / an invalid PTE, whichever comes first).
  //
  // NOTE: this is the C910 per-access-type rule, which intentionally DIFFERS
  // from a walker that checks every PTE read as READ, and from Whisper
  // (READ-as-User). Whisper PMP is neutralized (mmu_scoreboard write_pmp), so
  // this predictor + pmp_deny() (final PA) are the sole PMP authority.
  function bit walk_pmp_deny(longint unsigned va, bit [1:0] priv,
                             bit is_read, bit is_write, bit is_execute);
    bit [26:0]       vpn[3];
    bit [27:0]       node_ppn;
    longint unsigned pte_addr;
    longint unsigned pte;
    bit [27:0]       pte_ppn;
    bit              leaf;

    if (!satp_sv39 || mem == null || cur_pmp == null) return 1'b0;

    // A non-canonical Sv39 VA page-faults BEFORE the walk starts, so there are
    // no PTE fetches to PMP-check. Without this the walk below fabricates PTE
    // addresses from VA[38:12] of an address the hardware never walked, and a
    // fabricated address landing in a deny region preempts the page-fault
    // match that Whisper and the DUT already agree on. (Whisper on such a VA:
    // "OUTCOME: FAULT INST_PAGE_FAULT, walks=0, (no walk recorded)".)
    if (va[63:39] != {25{va[38]}}) return 1'b0;

    vpn[0] = va[20:12];
    vpn[1] = va[29:21];
    vpn[2] = va[38:30];
    node_ppn = satp_root_ppn;

    // Walk levels 2 -> 1 -> 0. Each PTE fetch is a physical read of the region
    // holding the node; check PMP on the PTE's PPN with the originating type.
    // A PTE fetch that matches NO PMP entry still faults outside M-mode: the
    // walker sees the priv-dependent default (4'h0 for S/U), so ptw_pmp_deny
    // asserts and aborts the walk. Do NOT gate this on a matched entry -- only
    // M-mode's default (4'b0111) permits.
    for (int lvl = 2; lvl >= 0; lvl--) begin
      pte_addr = ({node_ppn, 12'b0}) + (longint'(vpn[lvl]) << 3);
      // PTE-fetch PMP check, including the no-match default (ct_mmu_ptw.v:648).
      if (pmp_deny(pte_addr[39:12], priv, is_read, is_write, is_execute, 1'b0))
        return 1'b1;
      pte = mem.read_8(pte_addr);
      if (!pte[0]) return 1'b0;                     // invalid PTE -> page fault, no PMP deny
      pte_ppn = pte[37:10];
      leaf    = pte[1] || pte[3];                   // R=1 or X=1 -> leaf
      if (leaf) return 1'b0;                        // leaf reached; final-PA PMP is pmp_deny()
      node_ppn = pte_ppn;                           // descend
    end
    return 1'b0;
  endfunction : walk_pmp_deny

endclass : mmu_c910_pma_pmp

`endif // MMU_C910_PMA_PMP_SV
