// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_tb_top.sv
//
// Top-level module for the OpenC910 MMU plain-UVM testbench.
//
// Responsibilities:
//   - generate the free-running CPU clock and the active-low reset,
//   - instantiate the mmu_if bundle and connect it 1:1 to ct_mmu_top,
//   - publish the virtual interface into the uvm_config_db,
//   - run_test().
//
// DUT inputs that have no owning agent are held at benign idle values here so
// the design elaborates and runs; everything else is driven by its agent.
//======================================================================

`ifndef MMU_TB_TOP_SV
`define MMU_TB_TOP_SV

`include "uvm_macros.svh"
`include "mmu_if.sv"

module mmu_tb_top;

  import uvm_pkg::*;
  import mmu_test_pkg::*;

  //--------------------------------------------------------------------
  // Clock / reset generation
  //--------------------------------------------------------------------
  localparam time CLK_PERIOD = 10ns;   // 100 MHz reference

  logic forever_cpuclk;
  logic cpurst_b;

  initial begin
    forever_cpuclk = 1'b0;
    forever #(CLK_PERIOD/2) forever_cpuclk = ~forever_cpuclk;
  end

  initial begin
    cpurst_b = 1'b0;                   // asserted (active low)
    repeat (10) @(posedge forever_cpuclk);
    cpurst_b = 1'b1;                   // released
  end

  //--------------------------------------------------------------------
  // Interface
  //--------------------------------------------------------------------
  mmu_if u_mmu_if (.forever_cpuclk(forever_cpuclk), .cpurst_b(cpurst_b));

  // Whitebox TLB backdoor (direct hierarchical reads of jTLB/iuTLB/duTLB),
  // used by the invalidation checker. No DPI -> works on VCS + Verilator.
  mmu_tlb_bd_if u_tlb_bd ();

  //--------------------------------------------------------------------
  // Idle tie-offs for DUT-input groups that have no owning agent, held
  // inactive so no spurious requests are issued.
  //
  // Signals owned by an agent are NOT driven here (a variable driven from both
  // this initial block and an agent's clocking block resolves to X). Owned:
  //   - CSR / privilege pins   -> mmu_csr_agent
  //   - IFU request pins       -> mmu_ifu_agent
  //   - PTW-mem response bus   -> mmu_ptwmem_agent (lsu_mmu_data/vld/bus_error)
  //   - LSU pipe0/1 request    -> mmu_lsu_agent (va0/1, vld, id, st_inst, abort0/1)
  //   - PMP responses          -> mmu_if itself (pmp_mmu_flg0..4, combinational)
  initial begin
    // Clock-gating / scan (no agent)
    u_mmu_if.cp0_mmu_icg_en        = 1'b1;   // keep clocks enabled
    u_mmu_if.pad_yy_icg_scan_en    = 1'b0;

    // LSU: pipe0/1 request pins (va0/1, vld, id, st_inst, abort0/1) are owned by
    // mmu_lsu_agent. pipe2 (PFU), stamo writeback, and vabuf are deferred, so they
    // stay tied off here.
    u_mmu_if.lsu_mmu_stamo_pa      = 28'b0;
    u_mmu_if.lsu_mmu_stamo_vld     = 1'b0;
    u_mmu_if.lsu_mmu_va2           = 28'b0;
    u_mmu_if.lsu_mmu_va2_vld       = 1'b0;
    u_mmu_if.lsu_mmu_vabuf0        = 28'b0;
    u_mmu_if.lsu_mmu_vabuf1        = 28'b0;

    // TLB maintenance (sfence.vma) strobes + cp0_mmu_tlb_all_inv are owned by
    // mmu_tlb_inv_agent's driver -- not tied off here.

    // PMP responses: pmp_mmu_flg0..4 are now driven combinationally inside
    // mmu_if (see the pmp_match()/always_comb responder there), not tied
    // off here. The interface's default pmp_cfg (one full-coverage RWX
    // entry) reproduces the old 4'hF behavior for pre-PMP-agent tests.

    // Misc
    u_mmu_if.biu_mmu_smp_disable   = 1'b0;
    u_mmu_if.hpcp_mmu_cnt_en       = 1'b0;
    u_mmu_if.rtu_mmu_bad_vpn       = 27'b0;
    u_mmu_if.rtu_mmu_expt_vld      = 1'b0;
    u_mmu_if.rtu_yy_xx_flush       = 1'b0;
  end

  //--------------------------------------------------------------------
  // DUT instantiation (ports connect 1:1 to the interface bundle)
  //--------------------------------------------------------------------
  ct_mmu_top u_dut (
    // Clock / reset
    .forever_cpuclk           (forever_cpuclk),
    .cpurst_b                 (cpurst_b),
    .cp0_mmu_icg_en           (u_mmu_if.cp0_mmu_icg_en),
    .pad_yy_icg_scan_en       (u_mmu_if.pad_yy_icg_scan_en),

    // CSR / CP0
    .cp0_mmu_cskyee           (u_mmu_if.cp0_mmu_cskyee),
    .cp0_mmu_maee             (u_mmu_if.cp0_mmu_maee),
    .cp0_mmu_mpp              (u_mmu_if.cp0_mmu_mpp),
    .cp0_mmu_mprv             (u_mmu_if.cp0_mmu_mprv),
    .cp0_mmu_mxr              (u_mmu_if.cp0_mmu_mxr),
    .cp0_mmu_no_op_req        (u_mmu_if.cp0_mmu_no_op_req),
    .cp0_mmu_ptw_en           (u_mmu_if.cp0_mmu_ptw_en),
    .cp0_mmu_reg_num          (u_mmu_if.cp0_mmu_reg_num),
    .cp0_mmu_satp_sel         (u_mmu_if.cp0_mmu_satp_sel),
    .cp0_mmu_sum              (u_mmu_if.cp0_mmu_sum),
    .cp0_mmu_tlb_all_inv      (u_mmu_if.cp0_mmu_tlb_all_inv),
    .cp0_mmu_wdata            (u_mmu_if.cp0_mmu_wdata),
    .cp0_mmu_wreg             (u_mmu_if.cp0_mmu_wreg),
    .cp0_yy_priv_mode         (u_mmu_if.cp0_yy_priv_mode),
    .mmu_cp0_cmplt            (u_mmu_if.mmu_cp0_cmplt),
    .mmu_cp0_data             (u_mmu_if.mmu_cp0_data),
    .mmu_cp0_satp_data        (u_mmu_if.mmu_cp0_satp_data),
    .mmu_cp0_tlb_done         (u_mmu_if.mmu_cp0_tlb_done),

    // IFU
    .ifu_mmu_abort            (u_mmu_if.ifu_mmu_abort),
    .ifu_mmu_va               (u_mmu_if.ifu_mmu_va),
    .ifu_mmu_va_vld           (u_mmu_if.ifu_mmu_va_vld),
    .mmu_ifu_buf              (u_mmu_if.mmu_ifu_buf),
    .mmu_ifu_ca               (u_mmu_if.mmu_ifu_ca),
    .mmu_ifu_deny             (u_mmu_if.mmu_ifu_deny),
    .mmu_ifu_pa               (u_mmu_if.mmu_ifu_pa),
    .mmu_ifu_pavld            (u_mmu_if.mmu_ifu_pavld),
    .mmu_ifu_pgflt            (u_mmu_if.mmu_ifu_pgflt),
    .mmu_ifu_sec              (u_mmu_if.mmu_ifu_sec),

    // LSU
    .lsu_mmu_abort0           (u_mmu_if.lsu_mmu_abort0),
    .lsu_mmu_abort1           (u_mmu_if.lsu_mmu_abort1),
    .lsu_mmu_id0              (u_mmu_if.lsu_mmu_id0),
    .lsu_mmu_id1              (u_mmu_if.lsu_mmu_id1),
    .lsu_mmu_st_inst0         (u_mmu_if.lsu_mmu_st_inst0),
    .lsu_mmu_st_inst1         (u_mmu_if.lsu_mmu_st_inst1),
    .lsu_mmu_stamo_pa         (u_mmu_if.lsu_mmu_stamo_pa),
    .lsu_mmu_stamo_vld        (u_mmu_if.lsu_mmu_stamo_vld),
    .lsu_mmu_va0              (u_mmu_if.lsu_mmu_va0),
    .lsu_mmu_va0_vld          (u_mmu_if.lsu_mmu_va0_vld),
    .lsu_mmu_va1              (u_mmu_if.lsu_mmu_va1),
    .lsu_mmu_va1_vld          (u_mmu_if.lsu_mmu_va1_vld),
    .lsu_mmu_va2              (u_mmu_if.lsu_mmu_va2),
    .lsu_mmu_va2_vld          (u_mmu_if.lsu_mmu_va2_vld),
    .lsu_mmu_vabuf0           (u_mmu_if.lsu_mmu_vabuf0),
    .lsu_mmu_vabuf1           (u_mmu_if.lsu_mmu_vabuf1),
    .mmu_lsu_access_fault0    (u_mmu_if.mmu_lsu_access_fault0),
    .mmu_lsu_access_fault1    (u_mmu_if.mmu_lsu_access_fault1),
    .mmu_lsu_buf0             (u_mmu_if.mmu_lsu_buf0),
    .mmu_lsu_buf1             (u_mmu_if.mmu_lsu_buf1),
    .mmu_lsu_ca0              (u_mmu_if.mmu_lsu_ca0),
    .mmu_lsu_ca1              (u_mmu_if.mmu_lsu_ca1),
    .mmu_lsu_mmu_en           (u_mmu_if.mmu_lsu_mmu_en),
    .mmu_lsu_pa0              (u_mmu_if.mmu_lsu_pa0),
    .mmu_lsu_pa0_vld          (u_mmu_if.mmu_lsu_pa0_vld),
    .mmu_lsu_pa1              (u_mmu_if.mmu_lsu_pa1),
    .mmu_lsu_pa1_vld          (u_mmu_if.mmu_lsu_pa1_vld),
    .mmu_lsu_pa2              (u_mmu_if.mmu_lsu_pa2),
    .mmu_lsu_pa2_err          (u_mmu_if.mmu_lsu_pa2_err),
    .mmu_lsu_pa2_vld          (u_mmu_if.mmu_lsu_pa2_vld),
    .mmu_lsu_page_fault0      (u_mmu_if.mmu_lsu_page_fault0),
    .mmu_lsu_page_fault1      (u_mmu_if.mmu_lsu_page_fault1),
    .mmu_lsu_sec0             (u_mmu_if.mmu_lsu_sec0),
    .mmu_lsu_sec1             (u_mmu_if.mmu_lsu_sec1),
    .mmu_lsu_sec2             (u_mmu_if.mmu_lsu_sec2),
    .mmu_lsu_sh0              (u_mmu_if.mmu_lsu_sh0),
    .mmu_lsu_sh1              (u_mmu_if.mmu_lsu_sh1),
    .mmu_lsu_share2           (u_mmu_if.mmu_lsu_share2),
    .mmu_lsu_so0              (u_mmu_if.mmu_lsu_so0),
    .mmu_lsu_so1              (u_mmu_if.mmu_lsu_so1),
    .mmu_lsu_stall0           (u_mmu_if.mmu_lsu_stall0),
    .mmu_lsu_stall1           (u_mmu_if.mmu_lsu_stall1),

    // PTW memory bus
    .lsu_mmu_bus_error        (u_mmu_if.lsu_mmu_bus_error),
    .lsu_mmu_data             (u_mmu_if.lsu_mmu_data),
    .lsu_mmu_data_vld         (u_mmu_if.lsu_mmu_data_vld),
    .mmu_lsu_data_req         (u_mmu_if.mmu_lsu_data_req),
    .mmu_lsu_data_req_addr    (u_mmu_if.mmu_lsu_data_req_addr),
    .mmu_lsu_data_req_size    (u_mmu_if.mmu_lsu_data_req_size),

    // TLB maintenance
    .lsu_mmu_tlb_all_inv      (u_mmu_if.lsu_mmu_tlb_all_inv),
    .lsu_mmu_tlb_asid         (u_mmu_if.lsu_mmu_tlb_asid),
    .lsu_mmu_tlb_asid_all_inv (u_mmu_if.lsu_mmu_tlb_asid_all_inv),
    .lsu_mmu_tlb_va           (u_mmu_if.lsu_mmu_tlb_va),
    .lsu_mmu_tlb_va_all_inv   (u_mmu_if.lsu_mmu_tlb_va_all_inv),
    .lsu_mmu_tlb_va_asid_inv  (u_mmu_if.lsu_mmu_tlb_va_asid_inv),
    .mmu_lsu_tlb_busy         (u_mmu_if.mmu_lsu_tlb_busy),
    .mmu_lsu_tlb_inv_done     (u_mmu_if.mmu_lsu_tlb_inv_done),
    .mmu_lsu_tlb_wakeup       (u_mmu_if.mmu_lsu_tlb_wakeup),

    // PMP
    .pmp_mmu_flg0             (u_mmu_if.pmp_mmu_flg0),
    .pmp_mmu_flg1             (u_mmu_if.pmp_mmu_flg1),
    .pmp_mmu_flg2             (u_mmu_if.pmp_mmu_flg2),
    .pmp_mmu_flg3             (u_mmu_if.pmp_mmu_flg3),
    .pmp_mmu_flg4             (u_mmu_if.pmp_mmu_flg4),
    .mmu_pmp_fetch3           (u_mmu_if.mmu_pmp_fetch3),
    .mmu_pmp_pa0              (u_mmu_if.mmu_pmp_pa0),
    .mmu_pmp_pa1              (u_mmu_if.mmu_pmp_pa1),
    .mmu_pmp_pa2              (u_mmu_if.mmu_pmp_pa2),
    .mmu_pmp_pa3              (u_mmu_if.mmu_pmp_pa3),
    .mmu_pmp_pa4              (u_mmu_if.mmu_pmp_pa4),

    // Misc
    .biu_mmu_smp_disable      (u_mmu_if.biu_mmu_smp_disable),
    .hpcp_mmu_cnt_en          (u_mmu_if.hpcp_mmu_cnt_en),
    .rtu_mmu_bad_vpn          (u_mmu_if.rtu_mmu_bad_vpn),
    .rtu_mmu_expt_vld         (u_mmu_if.rtu_mmu_expt_vld),
    .rtu_yy_xx_flush          (u_mmu_if.rtu_yy_xx_flush),
    .mmu_had_debug_info       (u_mmu_if.mmu_had_debug_info),
    .mmu_hpcp_dutlb_miss      (u_mmu_if.mmu_hpcp_dutlb_miss),
    .mmu_hpcp_iutlb_miss      (u_mmu_if.mmu_hpcp_iutlb_miss),
    .mmu_hpcp_jtlb_miss       (u_mmu_if.mmu_hpcp_jtlb_miss),
    .mmu_xx_mmu_en            (u_mmu_if.mmu_xx_mmu_en),
    .mmu_yy_xx_no_op          (u_mmu_if.mmu_yy_xx_no_op)
  );

  //--------------------------------------------------------------------
  // UVM bring-up
  //--------------------------------------------------------------------
  // JTLB SRAM zero-init.
  //
  // The FPGA behavioural RAM model (fpga_ram) has no reset/init, so the JTLB
  // tag/data SRAMs power up as X. That makes the JTLB hit/miss compare X and
  // the walk stalls (the PTW is never triggered). Real silicon boots with the
  // TLB flushed; here we emulate that by zeroing the JTLB SRAM contents at t=0
  // (valid bits -> 0 => clean miss => PTW runs). Sim-only hierarchical init.
  initial begin
    for (int i = 0; i < 256; i++) begin
      // Tag array: ct_spsram_256x196 -> ct_f_spsram_256x196 -> ram0..ram4
      u_dut.x_ct_mmu_jtlb.x_ct_mmu_jtlb_tag_array.x_ct_spsram_256x196.x_ct_f_spsram_256x196.ram0.mem[i] = '0;
      u_dut.x_ct_mmu_jtlb.x_ct_mmu_jtlb_tag_array.x_ct_spsram_256x196.x_ct_f_spsram_256x196.ram1.mem[i] = '0;
      u_dut.x_ct_mmu_jtlb.x_ct_mmu_jtlb_tag_array.x_ct_spsram_256x196.x_ct_f_spsram_256x196.ram2.mem[i] = '0;
      u_dut.x_ct_mmu_jtlb.x_ct_mmu_jtlb_tag_array.x_ct_spsram_256x196.x_ct_f_spsram_256x196.ram3.mem[i] = '0;
      u_dut.x_ct_mmu_jtlb.x_ct_mmu_jtlb_tag_array.x_ct_spsram_256x196.x_ct_f_spsram_256x196.ram4.mem[i] = '0;
      // Data array: two banks, each ct_spsram_256x84 -> ct_f_spsram_256x84 -> ram0/ram1
      u_dut.x_ct_mmu_jtlb.x_ct_mmu_jtlb_data_array.x_ct_spsram_256x84_bank0.x_ct_f_spsram_256x84.ram0.mem[i] = '0;
      u_dut.x_ct_mmu_jtlb.x_ct_mmu_jtlb_data_array.x_ct_spsram_256x84_bank0.x_ct_f_spsram_256x84.ram1.mem[i] = '0;
      u_dut.x_ct_mmu_jtlb.x_ct_mmu_jtlb_data_array.x_ct_spsram_256x84_bank1.x_ct_f_spsram_256x84.ram0.mem[i] = '0;
      u_dut.x_ct_mmu_jtlb.x_ct_mmu_jtlb_data_array.x_ct_spsram_256x84_bank1.x_ct_f_spsram_256x84.ram1.mem[i] = '0;
    end
  end

  initial begin
    // Standard $dump* waveform (VCD, or FST when Verilated with --trace-fst).
    // Enable with +wave; filename overridable via +wavefile=<path>.
    if ($test$plusargs("wave")) begin
      string wave_file = "build/dump.vcd";
      void'($value$plusargs("wavefile=%s", wave_file));
      $dumpfile(wave_file);
      $dumpvars(0, mmu_tb_top);
    end
    // FSDB (Verdi); file via +fsdbfile=<path>. $fsdbDump* resolves at COMPILE
    // time from Verdi's PLI, so build it in only when Verdi was found.
`ifdef FSDB_EN
    if ($test$plusargs("fsdb")) begin
      string fsdb_file = "dump.fsdb";
      void'($value$plusargs("fsdbfile=%s", fsdb_file));
      $fsdbDumpfile(fsdb_file);
      $fsdbDumpvars(0, mmu_tb_top, "+all");
    end
`endif
  end

  initial begin
    uvm_config_db#(virtual mmu_if)::set(null, "*", "mmu_vif", u_mmu_if);
    uvm_config_db#(virtual mmu_tlb_bd_if)::set(null, "*", "tlb_bd_vif", u_tlb_bd);
    run_test("mmu_base_test");
  end

endmodule : mmu_tb_top

`endif // MMU_TB_TOP_SV
