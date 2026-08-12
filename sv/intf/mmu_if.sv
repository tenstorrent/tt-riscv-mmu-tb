// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_if.sv
//
// SystemVerilog interface for the OpenC910 MMU (ct_mmu_top).
//
// This interface bundles every signal on the DUT boundary, grouped by
// functional interface (clock/reset, IFU, LSU, PTW memory, PMP, CSR,
// TLB-maintenance, and misc). Signal names and widths mirror the RTL
// ports exactly so the top-level connection is 1:1.
//======================================================================

`ifndef MMU_IF_SV
`define MMU_IF_SV

interface mmu_if (input logic forever_cpuclk, input logic cpurst_b);

  //--------------------------------------------------------------------
  // Clock / reset / clock-gating
  //--------------------------------------------------------------------
  logic         cp0_mmu_icg_en;
  logic         pad_yy_icg_scan_en;

  //--------------------------------------------------------------------
  // CSR / CP0 control
  //--------------------------------------------------------------------
  logic         cp0_mmu_cskyee;
  logic         cp0_mmu_maee;
  logic  [1:0]  cp0_mmu_mpp;
  logic         cp0_mmu_mprv;
  logic         cp0_mmu_mxr;
  logic         cp0_mmu_no_op_req;
  logic         cp0_mmu_ptw_en;
  logic  [1:0]  cp0_mmu_reg_num;
  logic         cp0_mmu_satp_sel;
  logic         cp0_mmu_sum;
  logic         cp0_mmu_tlb_all_inv;
  logic  [63:0] cp0_mmu_wdata;
  logic         cp0_mmu_wreg;
  logic  [1:0]  cp0_yy_priv_mode;
  logic         mmu_cp0_cmplt;
  logic  [63:0] mmu_cp0_data;
  logic  [63:0] mmu_cp0_satp_data;
  logic         mmu_cp0_tlb_done;

  //--------------------------------------------------------------------
  // IFU (instruction-fetch translation)
  //--------------------------------------------------------------------
  logic         ifu_mmu_abort;
  logic  [62:0] ifu_mmu_va;
  logic         ifu_mmu_va_vld;
  logic         mmu_ifu_buf;
  logic         mmu_ifu_ca;
  logic         mmu_ifu_deny;
  logic  [27:0] mmu_ifu_pa;
  logic         mmu_ifu_pavld;
  logic         mmu_ifu_pgflt;
  logic         mmu_ifu_sec;

  //--------------------------------------------------------------------
  // LSU (data translation)
  //--------------------------------------------------------------------
  logic         lsu_mmu_abort0;
  logic         lsu_mmu_abort1;
  logic  [6:0]  lsu_mmu_id0;
  logic  [6:0]  lsu_mmu_id1;
  logic         lsu_mmu_st_inst0;
  logic         lsu_mmu_st_inst1;
  logic  [27:0] lsu_mmu_stamo_pa;
  logic         lsu_mmu_stamo_vld;
  logic  [63:0] lsu_mmu_va0;
  logic         lsu_mmu_va0_vld;
  logic  [63:0] lsu_mmu_va1;
  logic         lsu_mmu_va1_vld;
  logic  [27:0] lsu_mmu_va2;
  logic         lsu_mmu_va2_vld;
  logic  [27:0] lsu_mmu_vabuf0;
  logic  [27:0] lsu_mmu_vabuf1;
  logic         mmu_lsu_access_fault0;
  logic         mmu_lsu_access_fault1;
  logic         mmu_lsu_buf0;
  logic         mmu_lsu_buf1;
  logic         mmu_lsu_ca0;
  logic         mmu_lsu_ca1;
  logic         mmu_lsu_mmu_en;
  logic  [27:0] mmu_lsu_pa0;
  logic         mmu_lsu_pa0_vld;
  logic  [27:0] mmu_lsu_pa1;
  logic         mmu_lsu_pa1_vld;
  logic  [27:0] mmu_lsu_pa2;
  logic         mmu_lsu_pa2_err;
  logic         mmu_lsu_pa2_vld;
  logic         mmu_lsu_page_fault0;
  logic         mmu_lsu_page_fault1;
  logic         mmu_lsu_sec0;
  logic         mmu_lsu_sec1;
  logic         mmu_lsu_sec2;
  logic         mmu_lsu_sh0;
  logic         mmu_lsu_sh1;
  logic         mmu_lsu_share2;
  logic         mmu_lsu_so0;
  logic         mmu_lsu_so1;
  logic         mmu_lsu_stall0;
  logic         mmu_lsu_stall1;

  //--------------------------------------------------------------------
  // PTW memory bus (page-table reads)
  //--------------------------------------------------------------------
  logic         lsu_mmu_bus_error;
  logic  [63:0] lsu_mmu_data;
  logic         lsu_mmu_data_vld;
  logic         mmu_lsu_data_req;
  logic  [39:0] mmu_lsu_data_req_addr;
  logic         mmu_lsu_data_req_size;

  //--------------------------------------------------------------------
  // TLB maintenance (sfence.vma)
  //--------------------------------------------------------------------
  logic         lsu_mmu_tlb_all_inv;
  logic  [15:0] lsu_mmu_tlb_asid;
  logic         lsu_mmu_tlb_asid_all_inv;
  logic  [26:0] lsu_mmu_tlb_va;
  logic         lsu_mmu_tlb_va_all_inv;
  logic         lsu_mmu_tlb_va_asid_inv;
  logic         mmu_lsu_tlb_busy;
  logic         mmu_lsu_tlb_inv_done;
  logic  [11:0] mmu_lsu_tlb_wakeup;

  //--------------------------------------------------------------------
  // PMP
  //--------------------------------------------------------------------
  logic  [3:0]  pmp_mmu_flg0;
  logic  [3:0]  pmp_mmu_flg1;
  logic  [3:0]  pmp_mmu_flg2;
  logic  [3:0]  pmp_mmu_flg3;
  logic  [3:0]  pmp_mmu_flg4;
  logic         mmu_pmp_fetch3;
  logic  [27:0] mmu_pmp_pa0;
  logic  [27:0] mmu_pmp_pa1;
  logic  [27:0] mmu_pmp_pa2;
  logic  [27:0] mmu_pmp_pa3;
  logic  [27:0] mmu_pmp_pa4;

  //--------------------------------------------------------------------
  // PMP config model + combinational responder
  //
  // The MMU's 5 PMP probe ports are combinational: pmp_mmu_flg0..4 respond
  // same-cycle to mmu_pmp_pa0..4, no request/valid handshake (see
  // rtl/openc910/.../pmp/rtl/ct_pmp_acc.v). pmp_cfg is public and written
  // directly by the driver, not through a clocking block.
  //
  // lo/hi are 29 bits (not 28, matching mmu_pmp_pa's width) so a full-PA
  // -space region's EXCLUSIVE upper bound hi=2^28 is representable; a
  // 28-bit hi would wrap to 0 (empty range). Mirrors sv/agents/pmp/mmu_pmp_config.sv.
  //--------------------------------------------------------------------
  typedef struct packed {
    bit        vld;
    bit [28:0] lo, hi;
    bit        r, w, x, l;
  } pmp_ent_t;

  pmp_ent_t pmp_cfg [16];

  // Default: one full-coverage RWX entry (== old pmp_mmu_flg*=4'hF tie-off)
  // so pre-PMP-agent tests don't regress against an empty config (which
  // would make every access no-match -> S/U deny). Task-3 driver overwrites
  // pmp_cfg from an mmu_pmp_config object.
  initial begin
    pmp_cfg[0] = '{1'b1, 29'h0, 29'h1000_0000 /* 2^28 */, 1'b1, 1'b1, 1'b1, 1'b0};
    for (int i = 1; i < 16; i++) pmp_cfg[i] = '0;
  end

  // Lowest-numbered valid entry with ppn in [lo,hi) -> raw {L,X,W,R}.
  // No match: priv-dependent default (ct_pmp_acc.v:256) -- 4'b0111 in
  // M-mode (priv==2'b11), else 4'h0.
  function automatic bit [3:0] pmp_match (bit [27:0] ppn, bit [1:0] priv);
    for (int i = 0; i < 16; i++)
      if (pmp_cfg[i].vld && ppn >= pmp_cfg[i].lo && ppn < pmp_cfg[i].hi)
        return {pmp_cfg[i].l, pmp_cfg[i].x, pmp_cfg[i].w, pmp_cfg[i].r};
    return (priv == 2'b11) ? 4'b0111 : 4'h0;
  endfunction

  // Effective privilege for PMP (ct_pmp_acc.v:107): DATA accesses honor MPRV
  // (use MPP when mprv=1), FETCH does not. So the data ports (pa0/pa1) and a
  // DATA-triggered walk (pa3 when !mmu_pmp_fetch3) use the effective priv; the
  // fetch port (pa2) and a FETCH-triggered walk use the current priv.
  wire [1:0] pmp_eff_priv = cp0_mmu_mprv ? cp0_mmu_mpp : cp0_yy_priv_mode;

  always_comb pmp_mmu_flg0 = pmp_match(mmu_pmp_pa0, pmp_eff_priv);
  always_comb pmp_mmu_flg1 = pmp_match(mmu_pmp_pa1, pmp_eff_priv);
  always_comb pmp_mmu_flg2 = pmp_match(mmu_pmp_pa2, cp0_yy_priv_mode);
  always_comb pmp_mmu_flg3 = pmp_match(mmu_pmp_pa3,
                                       mmu_pmp_fetch3 ? cp0_yy_priv_mode : pmp_eff_priv);
  always_comb pmp_mmu_flg4 = pmp_match(mmu_pmp_pa4, pmp_eff_priv);

  //--------------------------------------------------------------------
  // Misc (RTU flush, HPCP, debug, SMP)
  //--------------------------------------------------------------------
  logic         biu_mmu_smp_disable;
  logic         hpcp_mmu_cnt_en;
  logic  [26:0] rtu_mmu_bad_vpn;
  logic         rtu_mmu_expt_vld;
  logic         rtu_yy_xx_flush;
  logic  [33:0] mmu_had_debug_info;
  logic         mmu_hpcp_dutlb_miss;
  logic         mmu_hpcp_iutlb_miss;
  logic         mmu_hpcp_jtlb_miss;
  logic         mmu_xx_mmu_en;
  logic         mmu_yy_xx_no_op;

  //--------------------------------------------------------------------
  // Clocking blocks / modports
  //
  // Added per functional group as agents come online (IFU first). Clocked on
  // forever_cpuclk. *_drv_cb: agent drives the DUT-input signals and samples the
  // DUT outputs; *_mon_cb: passive sampling of the whole group. csr/ptw_mem/lsu
  // clocking is added with their agents.
  //--------------------------------------------------------------------

  // IFU (instruction-fetch translation) — used by mmu_ifu_agent
  clocking ifu_drv_cb @(posedge forever_cpuclk);
    default input #1step output #1;
    output ifu_mmu_va, ifu_mmu_va_vld, ifu_mmu_abort;
    input  mmu_ifu_pa, mmu_ifu_pavld, mmu_ifu_ca, mmu_ifu_sec,
           mmu_ifu_buf, mmu_ifu_pgflt, mmu_ifu_deny;
  endclocking

  clocking ifu_mon_cb @(posedge forever_cpuclk);
    default input #1step;
    input ifu_mmu_va, ifu_mmu_va_vld, ifu_mmu_abort,
          mmu_ifu_pa, mmu_ifu_pavld, mmu_ifu_ca, mmu_ifu_sec,
          mmu_ifu_buf, mmu_ifu_pgflt, mmu_ifu_deny,
          cp0_yy_priv_mode,   // current privilege at the fetch cycle (U/S/M)
          cp0_mmu_sum;        // C910 applies SUM to FETCH too (ct_mmu_iutlb.v:599)
  endclocking

  modport ifu_drv (clocking ifu_drv_cb);
  modport ifu_mon (clocking ifu_mon_cb);

  // CSR / CP0 (satp + control/enable + mstatus/priv context) — used by mmu_csr_agent
  clocking csr_drv_cb @(posedge forever_cpuclk);
    default input #1step output #1;
    output cp0_mmu_wreg, cp0_mmu_wdata, cp0_mmu_reg_num, cp0_mmu_satp_sel,
           cp0_mmu_no_op_req, cp0_mmu_ptw_en, cp0_mmu_cskyee, cp0_mmu_maee,
           cp0_yy_priv_mode, cp0_mmu_mprv, cp0_mmu_mpp, cp0_mmu_mxr, cp0_mmu_sum;
    input  mmu_cp0_cmplt, mmu_cp0_data, mmu_cp0_satp_data, mmu_cp0_tlb_done, mmu_xx_mmu_en,
           mmu_yy_xx_no_op;   // MMU idle: 1 => no translation in flight
  endclocking

  clocking csr_mon_cb @(posedge forever_cpuclk);
    default input #1step;
    input cp0_mmu_wreg, cp0_mmu_wdata, cp0_mmu_reg_num, cp0_mmu_satp_sel,
          cp0_mmu_ptw_en, cp0_yy_priv_mode, cp0_mmu_mprv, cp0_mmu_mpp,
          cp0_mmu_mxr, cp0_mmu_sum,
          mmu_cp0_cmplt, mmu_cp0_data, mmu_cp0_satp_data, mmu_cp0_tlb_done, mmu_xx_mmu_en;
  endclocking

  modport csr_drv (clocking csr_drv_cb);
  modport csr_mon (clocking csr_mon_cb);

  // TLB invalidation (sfence.vma). Driver owns the lsu_mmu_tlb_* strobes +
  // cp0_mmu_tlb_all_inv; monitor observes them + the mmu_lsu_tlb_inv_done pulse.
  clocking inv_drv_cb @(posedge forever_cpuclk);
    default input #1step output #1;
    output lsu_mmu_tlb_all_inv, lsu_mmu_tlb_asid, lsu_mmu_tlb_asid_all_inv,
           lsu_mmu_tlb_va, lsu_mmu_tlb_va_all_inv, lsu_mmu_tlb_va_asid_inv,
           cp0_mmu_tlb_all_inv;
    input  mmu_lsu_tlb_inv_done, mmu_cp0_tlb_done, mmu_lsu_tlb_busy;
  endclocking

  clocking inv_mon_cb @(posedge forever_cpuclk);
    default input #1step;
    input  lsu_mmu_tlb_all_inv, lsu_mmu_tlb_asid, lsu_mmu_tlb_asid_all_inv,
           lsu_mmu_tlb_va, lsu_mmu_tlb_va_all_inv, lsu_mmu_tlb_va_asid_inv,
           cp0_mmu_tlb_all_inv, mmu_lsu_tlb_inv_done, mmu_cp0_tlb_done,
           mmu_lsu_tlb_busy;
  endclocking

  modport inv_drv (clocking inv_drv_cb);
  modport inv_mon (clocking inv_mon_cb);

  // PTW memory bus (page-table reads) — used by mmu_ptwmem_agent (responder).
  // The DUT is the requester (mmu_lsu_data_req/addr/size); the TB responds with
  // the 8-byte PTE (lsu_mmu_data/vld) and optional bus_error.
  clocking ptwmem_drv_cb @(posedge forever_cpuclk);
    default input #1step output #1;
    input  mmu_lsu_data_req, mmu_lsu_data_req_addr, mmu_lsu_data_req_size;
    output lsu_mmu_data, lsu_mmu_data_vld, lsu_mmu_bus_error;
  endclocking

  clocking ptwmem_mon_cb @(posedge forever_cpuclk);
    default input #1step;
    input mmu_lsu_data_req, mmu_lsu_data_req_addr, mmu_lsu_data_req_size,
          lsu_mmu_data, lsu_mmu_data_vld, lsu_mmu_bus_error;
  endclocking

  modport ptwmem_drv (clocking ptwmem_drv_cb);
  modport ptwmem_mon (clocking ptwmem_mon_cb);

  // LSU (data translation, pipe0/1 fast pipes) — used by mmu_lsu_agent.
  // The agent owns the pipe0/1 REQUEST pins (va/vld/id/st_inst/abort) and drives
  // both pipes; pipe2 (PFU), stamo, and vabuf stay TB-tied (deferred). tlb_busy /
  // tlb_wakeup are sampled by the driver for the miss -> wakeup -> replay flow.
  clocking lsu_drv_cb @(posedge forever_cpuclk);
    default input #1step output #1;
    output lsu_mmu_va0, lsu_mmu_va0_vld, lsu_mmu_id0, lsu_mmu_st_inst0, lsu_mmu_abort0,
           lsu_mmu_va1, lsu_mmu_va1_vld, lsu_mmu_id1, lsu_mmu_st_inst1, lsu_mmu_abort1;
    input  mmu_lsu_pa0, mmu_lsu_pa0_vld, mmu_lsu_page_fault0, mmu_lsu_access_fault0,
           mmu_lsu_ca0, mmu_lsu_sec0, mmu_lsu_sh0, mmu_lsu_so0, mmu_lsu_buf0,
           mmu_lsu_pa1, mmu_lsu_pa1_vld, mmu_lsu_page_fault1, mmu_lsu_access_fault1,
           mmu_lsu_ca1, mmu_lsu_sec1, mmu_lsu_sh1, mmu_lsu_so1, mmu_lsu_buf1,
           mmu_lsu_stall0, mmu_lsu_stall1, mmu_lsu_tlb_busy, mmu_lsu_tlb_wakeup,
           mmu_lsu_mmu_en;
  endclocking

  clocking lsu_mon_cb @(posedge forever_cpuclk);
    default input #1step;
    input lsu_mmu_va0, lsu_mmu_va0_vld, lsu_mmu_id0, lsu_mmu_st_inst0, lsu_mmu_abort0,
          lsu_mmu_va1, lsu_mmu_va1_vld, lsu_mmu_id1, lsu_mmu_st_inst1, lsu_mmu_abort1,
          mmu_lsu_pa0, mmu_lsu_pa0_vld, mmu_lsu_page_fault0, mmu_lsu_access_fault0,
          mmu_lsu_ca0, mmu_lsu_sec0, mmu_lsu_sh0, mmu_lsu_so0, mmu_lsu_buf0,
          mmu_lsu_pa1, mmu_lsu_pa1_vld, mmu_lsu_page_fault1, mmu_lsu_access_fault1,
          mmu_lsu_ca1, mmu_lsu_sec1, mmu_lsu_sh1, mmu_lsu_so1, mmu_lsu_buf1,
          mmu_lsu_tlb_busy, mmu_lsu_tlb_wakeup,
          cp0_yy_priv_mode, cp0_mmu_mprv, cp0_mmu_mpp, cp0_mmu_sum, cp0_mmu_mxr;
  endclocking

  modport lsu_drv (clocking lsu_drv_cb);
  modport lsu_mon (clocking lsu_mon_cb);

  // PMP (combinational responder) — used by mmu_pmp_agent.
  // pmp_mmu_flg0..4 are driven by the always_comb responder above, not by a
  // driver output, and pmp_cfg is written directly (not via a CB), so
  // pmp_drv_cb is a stub mirroring ifu_drv_cb for interface symmetry + a
  // modport (no `output` signals: there is nothing to drive here).
  clocking pmp_drv_cb @(posedge forever_cpuclk);
    default input #1step output #1;
    input mmu_pmp_pa0, mmu_pmp_pa1, mmu_pmp_pa2, mmu_pmp_pa3, mmu_pmp_pa4,
          mmu_pmp_fetch3, cp0_yy_priv_mode;
  endclocking

  clocking pmp_mon_cb @(posedge forever_cpuclk);
    default input #1step;
    input mmu_pmp_pa0, mmu_pmp_pa1, mmu_pmp_pa2, mmu_pmp_pa3, mmu_pmp_pa4,
          mmu_pmp_fetch3, cp0_yy_priv_mode;
  endclocking

  modport pmp_drv (clocking pmp_drv_cb);
  modport pmp_mon (clocking pmp_mon_cb);

endinterface : mmu_if

`endif // MMU_IF_SV
