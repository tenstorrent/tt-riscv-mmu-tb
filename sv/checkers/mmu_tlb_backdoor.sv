// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_tlb_backdoor.sv
//
// Whitebox backdoor reader for the C910 TLBs, used by the invalidation checker
// to verify a flush. DPI-free: uses uvm_hdl_read on the DUT's storage nets.
//
// Structure (confirmed from RTL, gen_rtl/mmu + gen_rtl/fpga):
//   jTLB: 256 sets x 4 ways. Tag SRAM (ct_f_spsram_256x196) holds one 48-bit
//     tag per way in fpga_ram sub-arrays ram4..ram1 (ram4=way0 .. ram1=way3),
//     each a `reg [47:0] mem [255:0]`. Per-way 48b tag:
//        [47]=valid  [46:20]=vpn[26:0]  [19:4]=asid[15:0]  [3:1]=pgs  [0]=global
//     Data SRAM (ct_f_spsram_256x84, 2 banks x 2 ways) holds 42b/way:
//        [41:14]=ppn[27:0]  [13:0]=flg   (bank0 ram0/ram1=way0/1, bank1=way2/3)
//   iuTLB: 32 flop entries; duTLB: 17 (16 + 1 huge). Per-entry nets:
//        utlb_vld / utlb_vpn[26:0] / utlb_ppn[27:0] / utlb_flg[13:0] (+utlb_pgs
//        on iuTLB & dutlb huge entry). uTLB stores NO asid/global.
//
// If a path does not resolve (e.g. a simulator flattens the mem), read_ok is
// cleared for that class and the checker degrades to handshake-only (never a
// silent pass) -- CAM checking is optional and degrades gracefully.
//======================================================================
`ifndef MMU_TLB_BACKDOOR_SV
`define MMU_TLB_BACKDOOR_SV

typedef struct packed {
  bit        vld;
  bit [26:0] vpn;
  bit [15:0] asid;
  bit [2:0]  pgs;     // one-hot 4K/2M/1G
  bit        g;
  bit [27:0] ppn;
} jtlb_entry_t;

typedef struct packed {
  bit        vld;
  bit [26:0] vpn;
  bit [27:0] ppn;
  bit [2:0]  pgs;
} utlb_entry_t;

class mmu_tlb_backdoor extends uvm_object;
  `uvm_object_utils(mmu_tlb_backdoor)

  // Direct-hierarchical backdoor interface (mmu_tlb_bd_if in tb_top). No DPI ->
  // works on VCS + Verilator, and reads cannot "fail" (compiled-in references).
  virtual mmu_tlb_bd_if vif;
  bit ok;   // 1 once the vif handle is obtained

  localparam int JTLB_SETS = 256;
  localparam int JTLB_WAYS = 4;
  localparam int IUTLB_N   = 32;
  localparam int DUTLB_N   = 17;   // 16 regular + entry16 huge

  function new(string name = "mmu_tlb_backdoor");
    super.new(name);
  endfunction

  // Obtain the backdoor interface handle (once). Returns 1 if available.
  function bit connect();
    if (ok) return 1;
    if (uvm_config_db#(virtual mmu_tlb_bd_if)::get(null, "*", "tlb_bd_vif", vif))
      ok = 1;
    return ok;
  endfunction

  // Read one jTLB (set,way) via the interface (tag + data). Never fails.
  function void read_jtlb(int set, int way, output jtlb_entry_t e);
    logic [47:0] tag = vif.jtlb_tag(set, way);
    logic [41:0] dat = vif.jtlb_data(set, way);
    e.vld  = tag[47];
    e.vpn  = tag[46:20];
    e.asid = tag[19:4];
    e.pgs  = tag[3:1];
    e.g    = tag[0];
    e.ppn  = dat[41:14];
  endfunction

  function void read_iutlb(int i, output utlb_entry_t e);
    logic [58:0] w = vif.iutlb(i);   // {vld, pgs[2:0], ppn[27:0], vpn[26:0]}
    e.vld = w[58];
    e.pgs = w[57:55];
    e.ppn = w[54:27];
    e.vpn = w[26:0];
  endfunction

  function void read_dutlb(int i, output utlb_entry_t e);
    logic [55:0] w = vif.dutlb(i);   // {vld, ppn[27:0], vpn[26:0]}
    e.vld = w[55];
    e.ppn = w[54:27];
    e.vpn = w[26:0];
    e.pgs = 3'b0;                    // regular dutlb entries are 4K (huge=entry16)
  endfunction

  // Count valid jTLB entries (confirm warm-up filled the TLB / post-flush empty).
  function int jtlb_valid_count();
    jtlb_entry_t e; int n = 0;
    for (int s = 0; s < JTLB_SETS; s++)
      for (int w = 0; w < JTLB_WAYS; w++) begin
        read_jtlb(s, w, e);
        if (e.vld) n++;
      end
    return n;
  endfunction

endclass : mmu_tlb_backdoor

`endif // MMU_TLB_BACKDOOR_SV
