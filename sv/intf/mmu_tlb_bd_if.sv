// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_tlb_bd_if.sv
//
// Whitebox TLB backdoor via DIRECT HIERARCHICAL REFERENCES into the DUT
// (a direct hierarchical-reference interface -- NOT uvm_hdl_read/DPI).
// Instantiated in mmu_tb_top; the checker gets a virtual handle from config_db
// and calls these functions. Works on BOTH VCS and Verilator (no DPI) and the
// reads cannot "fail" (compiled-in references), so no availability guard is
// needed. `DUT is the hierarchical path to the ct_mmu_top instance.
//
// Layout (RTL-confirmed):
//   jTLB tag SRAM ct_f_spsram_256x196: ram4=way0..ram1=way3, each reg[47:0]mem[255:0]
//     48b tag: [47]=vld [46:20]=vpn [19:4]=asid [3:1]=pgs [0]=g
//   jTLB data SRAM ct_f_spsram_256x84: bank0 ram0/ram1=way0/1, bank1=way2/3, reg[41:0]
//     42b: [41:14]=ppn [13:0]=flg
//   iuTLB 32 entries / duTLB 17 (16 + entry16 huge): per-entry regs
//     utlb_vld / utlb_vpn[26:0] / utlb_ppn[27:0] (+utlb_pgs[2:0] on iuTLB).
//======================================================================
`ifndef MMU_TLB_BD_IF_SV
`define MMU_TLB_BD_IF_SV

`define DUT mmu_tb_top.u_dut

interface mmu_tlb_bd_if;

  // ---- jTLB tag: way -> ramN.mem[set] (48b) ----
  function automatic logic [47:0] jtlb_tag(int set, int way);
    case (way)
      0: return `DUT.x_ct_mmu_jtlb.x_ct_mmu_jtlb_tag_array.x_ct_spsram_256x196.x_ct_f_spsram_256x196.ram4.mem[set];
      1: return `DUT.x_ct_mmu_jtlb.x_ct_mmu_jtlb_tag_array.x_ct_spsram_256x196.x_ct_f_spsram_256x196.ram3.mem[set];
      2: return `DUT.x_ct_mmu_jtlb.x_ct_mmu_jtlb_tag_array.x_ct_spsram_256x196.x_ct_f_spsram_256x196.ram2.mem[set];
      3: return `DUT.x_ct_mmu_jtlb.x_ct_mmu_jtlb_tag_array.x_ct_spsram_256x196.x_ct_f_spsram_256x196.ram1.mem[set];
      default: return '0;
    endcase
  endfunction

  // ---- jTLB data: 42b (ppn+flg) ----
  function automatic logic [41:0] jtlb_data(int set, int way);
    case (way)
      0: return `DUT.x_ct_mmu_jtlb.x_ct_mmu_jtlb_data_array.x_ct_spsram_256x84_bank0.x_ct_f_spsram_256x84.ram0.mem[set];
      1: return `DUT.x_ct_mmu_jtlb.x_ct_mmu_jtlb_data_array.x_ct_spsram_256x84_bank0.x_ct_f_spsram_256x84.ram1.mem[set];
      2: return `DUT.x_ct_mmu_jtlb.x_ct_mmu_jtlb_data_array.x_ct_spsram_256x84_bank1.x_ct_f_spsram_256x84.ram0.mem[set];
      3: return `DUT.x_ct_mmu_jtlb.x_ct_mmu_jtlb_data_array.x_ct_spsram_256x84_bank1.x_ct_f_spsram_256x84.ram1.mem[set];
      default: return '0;
    endcase
  endfunction

  // ---- iuTLB entry i -> packed {vld, pgs[2:0], ppn[27:0], vpn[26:0]} (59b) ----
  `define IU(n) `DUT.x_ct_mmu_iutlb.x_ct_mmu_iutlb_entry``n
  function automatic logic [58:0] iutlb(int i);
    case (i)
      0:  return {`IU(0).utlb_vld, `IU(0).utlb_pgs, `IU(0).utlb_ppn, `IU(0).utlb_vpn};
      1:  return {`IU(1).utlb_vld, `IU(1).utlb_pgs, `IU(1).utlb_ppn, `IU(1).utlb_vpn};
      2:  return {`IU(2).utlb_vld, `IU(2).utlb_pgs, `IU(2).utlb_ppn, `IU(2).utlb_vpn};
      3:  return {`IU(3).utlb_vld, `IU(3).utlb_pgs, `IU(3).utlb_ppn, `IU(3).utlb_vpn};
      4:  return {`IU(4).utlb_vld, `IU(4).utlb_pgs, `IU(4).utlb_ppn, `IU(4).utlb_vpn};
      5:  return {`IU(5).utlb_vld, `IU(5).utlb_pgs, `IU(5).utlb_ppn, `IU(5).utlb_vpn};
      6:  return {`IU(6).utlb_vld, `IU(6).utlb_pgs, `IU(6).utlb_ppn, `IU(6).utlb_vpn};
      7:  return {`IU(7).utlb_vld, `IU(7).utlb_pgs, `IU(7).utlb_ppn, `IU(7).utlb_vpn};
      8:  return {`IU(8).utlb_vld, `IU(8).utlb_pgs, `IU(8).utlb_ppn, `IU(8).utlb_vpn};
      9:  return {`IU(9).utlb_vld, `IU(9).utlb_pgs, `IU(9).utlb_ppn, `IU(9).utlb_vpn};
      10: return {`IU(10).utlb_vld, `IU(10).utlb_pgs, `IU(10).utlb_ppn, `IU(10).utlb_vpn};
      11: return {`IU(11).utlb_vld, `IU(11).utlb_pgs, `IU(11).utlb_ppn, `IU(11).utlb_vpn};
      12: return {`IU(12).utlb_vld, `IU(12).utlb_pgs, `IU(12).utlb_ppn, `IU(12).utlb_vpn};
      13: return {`IU(13).utlb_vld, `IU(13).utlb_pgs, `IU(13).utlb_ppn, `IU(13).utlb_vpn};
      14: return {`IU(14).utlb_vld, `IU(14).utlb_pgs, `IU(14).utlb_ppn, `IU(14).utlb_vpn};
      15: return {`IU(15).utlb_vld, `IU(15).utlb_pgs, `IU(15).utlb_ppn, `IU(15).utlb_vpn};
      16: return {`IU(16).utlb_vld, `IU(16).utlb_pgs, `IU(16).utlb_ppn, `IU(16).utlb_vpn};
      17: return {`IU(17).utlb_vld, `IU(17).utlb_pgs, `IU(17).utlb_ppn, `IU(17).utlb_vpn};
      18: return {`IU(18).utlb_vld, `IU(18).utlb_pgs, `IU(18).utlb_ppn, `IU(18).utlb_vpn};
      19: return {`IU(19).utlb_vld, `IU(19).utlb_pgs, `IU(19).utlb_ppn, `IU(19).utlb_vpn};
      20: return {`IU(20).utlb_vld, `IU(20).utlb_pgs, `IU(20).utlb_ppn, `IU(20).utlb_vpn};
      21: return {`IU(21).utlb_vld, `IU(21).utlb_pgs, `IU(21).utlb_ppn, `IU(21).utlb_vpn};
      22: return {`IU(22).utlb_vld, `IU(22).utlb_pgs, `IU(22).utlb_ppn, `IU(22).utlb_vpn};
      23: return {`IU(23).utlb_vld, `IU(23).utlb_pgs, `IU(23).utlb_ppn, `IU(23).utlb_vpn};
      24: return {`IU(24).utlb_vld, `IU(24).utlb_pgs, `IU(24).utlb_ppn, `IU(24).utlb_vpn};
      25: return {`IU(25).utlb_vld, `IU(25).utlb_pgs, `IU(25).utlb_ppn, `IU(25).utlb_vpn};
      26: return {`IU(26).utlb_vld, `IU(26).utlb_pgs, `IU(26).utlb_ppn, `IU(26).utlb_vpn};
      27: return {`IU(27).utlb_vld, `IU(27).utlb_pgs, `IU(27).utlb_ppn, `IU(27).utlb_vpn};
      28: return {`IU(28).utlb_vld, `IU(28).utlb_pgs, `IU(28).utlb_ppn, `IU(28).utlb_vpn};
      29: return {`IU(29).utlb_vld, `IU(29).utlb_pgs, `IU(29).utlb_ppn, `IU(29).utlb_vpn};
      30: return {`IU(30).utlb_vld, `IU(30).utlb_pgs, `IU(30).utlb_ppn, `IU(30).utlb_vpn};
      31: return {`IU(31).utlb_vld, `IU(31).utlb_pgs, `IU(31).utlb_ppn, `IU(31).utlb_vpn};
      default: return '0;
    endcase
  endfunction

  // ---- duTLB entry i -> packed {vld, ppn[27:0], vpn[26:0]} (56b). entry16=huge. ----
  `define DU(n) `DUT.x_ct_mmu_dutlb.x_ct_mmu_dutlb_entry``n
  function automatic logic [55:0] dutlb(int i);
    case (i)
      0:  return {`DU(0).utlb_vld, `DU(0).utlb_ppn, `DU(0).utlb_vpn};
      1:  return {`DU(1).utlb_vld, `DU(1).utlb_ppn, `DU(1).utlb_vpn};
      2:  return {`DU(2).utlb_vld, `DU(2).utlb_ppn, `DU(2).utlb_vpn};
      3:  return {`DU(3).utlb_vld, `DU(3).utlb_ppn, `DU(3).utlb_vpn};
      4:  return {`DU(4).utlb_vld, `DU(4).utlb_ppn, `DU(4).utlb_vpn};
      5:  return {`DU(5).utlb_vld, `DU(5).utlb_ppn, `DU(5).utlb_vpn};
      6:  return {`DU(6).utlb_vld, `DU(6).utlb_ppn, `DU(6).utlb_vpn};
      7:  return {`DU(7).utlb_vld, `DU(7).utlb_ppn, `DU(7).utlb_vpn};
      8:  return {`DU(8).utlb_vld, `DU(8).utlb_ppn, `DU(8).utlb_vpn};
      9:  return {`DU(9).utlb_vld, `DU(9).utlb_ppn, `DU(9).utlb_vpn};
      10: return {`DU(10).utlb_vld, `DU(10).utlb_ppn, `DU(10).utlb_vpn};
      11: return {`DU(11).utlb_vld, `DU(11).utlb_ppn, `DU(11).utlb_vpn};
      12: return {`DU(12).utlb_vld, `DU(12).utlb_ppn, `DU(12).utlb_vpn};
      13: return {`DU(13).utlb_vld, `DU(13).utlb_ppn, `DU(13).utlb_vpn};
      14: return {`DU(14).utlb_vld, `DU(14).utlb_ppn, `DU(14).utlb_vpn};
      15: return {`DU(15).utlb_vld, `DU(15).utlb_ppn, `DU(15).utlb_vpn};
      16: return {`DU(16).utlb_vld, `DU(16).utlb_ppn, `DU(16).utlb_vpn};
      default: return '0;
    endcase
  endfunction

  // ---- iuTLB refill state: has the last walk's fault retired? ----
  // Covers the two indications that outlive a fetch: iutlb_ref_pgflt
  // (= ref_cur_st == PGFLT) and the registered jtlb_acc_fault_flop.
  // Deliberately iuTLB-local -- the shared PTW/jTLB FSMs stay busy under
  // continuous traffic and would never settle.
  function automatic bit iutlb_fault_settled();
    return (`DUT.x_ct_mmu_iutlb.ref_cur_st == 3'b000) &&    // IDLE
           !`DUT.x_ct_mmu_iutlb.jtlb_acc_fault_flop;
  endfunction

endinterface : mmu_tlb_bd_if

`undef IU
`undef DU
`undef DUT
`endif // MMU_TLB_BD_IF_SV
