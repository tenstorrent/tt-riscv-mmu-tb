// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_csr_driver.sv
//
// Driver for the CSR / CP0 agent (generic register write).
//
//   CTX_SET   : update the held *level* pins (priv/mstatus/enables).
//   REG_WRITE : pulse a register write — SATP via cp0_mmu_satp_sel, the
//               T-Head regs via cp0_mmu_reg_num, together with cp0_mmu_wreg
//               + cp0_mmu_wdata. The write registers on the clock edge;
//               it does NOT wait for mmu_cp0_cmplt (that only pulses for
//               tlboper/MCIR ops per ct_mmu_regs.v). Not modelled here:
//               tlboper/MCIR completion (mmu_cp0_cmplt/tlb_done) handling --
//               TLB maintenance is driven by the tlb_inv agent instead.
//
// Drive-only — the monitor observes cmplt/satp_data/mmu_en. Reset-gated.
// Initial held context matches the TB-top idle tie-offs (M-mode, PTW enabled).
//======================================================================
`ifndef MMU_CSR_DRIVER_SV
`define MMU_CSR_DRIVER_SV

class mmu_csr_driver extends uvm_driver #(mmu_csr_seq_item);
  `uvm_component_utils(mmu_csr_driver)

  virtual mmu_if vif;

  // reg_num encoding (ct_mmu_regs.v)
  localparam bit [1:0] REGNUM_MIR  = 2'd0;
  localparam bit [1:0] REGNUM_MEL  = 2'd1;
  localparam bit [1:0] REGNUM_MEH  = 2'd2;
  localparam bit [1:0] REGNUM_MCIR = 2'd3;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual mmu_if)::get(this, "", "mmu_vif", vif))
      `uvm_fatal(get_type_name(), "mmu_vif not found in config DB")
  endfunction

  task run_phase(uvm_phase phase);
    drive_idle();
    wait (vif.cpurst_b === 1'b1);
    forever begin
      seq_item_port.get_next_item(req);
      apply(req);
      seq_item_port.item_done();
    end
  endtask

  // No write; sane default level context (matches the TB-top tie-offs).
  protected task drive_idle();
    vif.csr_drv_cb.cp0_mmu_wreg      <= 1'b0;
    vif.csr_drv_cb.cp0_mmu_satp_sel  <= 1'b0;
    vif.csr_drv_cb.cp0_mmu_reg_num   <= '0;
    vif.csr_drv_cb.cp0_mmu_wdata     <= '0;
    vif.csr_drv_cb.cp0_yy_priv_mode  <= 2'b11;   // M-mode
    vif.csr_drv_cb.cp0_mmu_mprv      <= 1'b0;
    vif.csr_drv_cb.cp0_mmu_mpp       <= 2'b00;
    vif.csr_drv_cb.cp0_mmu_mxr       <= 1'b0;
    vif.csr_drv_cb.cp0_mmu_sum       <= 1'b0;
    vif.csr_drv_cb.cp0_mmu_ptw_en    <= 1'b1;    // allow HW walks
    vif.csr_drv_cb.cp0_mmu_maee      <= 1'b0;
    vif.csr_drv_cb.cp0_mmu_cskyee    <= 1'b0;
    vif.csr_drv_cb.cp0_mmu_no_op_req <= 1'b0;
  endtask

  // Wait until the MMU is idle (no translation in flight) before changing the
  // privilege/context -- wait for idle first, because a context change must
  // only land between translations, never mid-walk (which would let an access
  // straddle two privileges with the duTLB's miss/replay latency). Bounded so a
  // stuck DUT can't hang the test.
  protected task wait_for_mmu_idle();
    int unsigned guard = 0;
    while (vif.csr_drv_cb.mmu_yy_xx_no_op !== 1'b1 && guard < 100000) begin
      @(vif.csr_drv_cb);
      guard++;
    end
  endtask

  protected task apply(mmu_csr_seq_item item);
    @(vif.csr_drv_cb);
    if (item.op == mmu_csr_seq_item::CTX_SET) begin
      // Dynamic-satp path: quiesce the MMU before swapping the translation
      // context so no access straddles the change. Only when the item asks for
      // it (the caller has drained its own traffic first, so idle is reachable).
      if (item.wait_idle) wait_for_mmu_idle();
      // NOTE: wait_for_mmu_idle() is intentionally NOT called on the normal
      // CTX_SET path -- mmu_yy_xx_no_op rarely asserts during continuous
      // fetch/data traffic, so gating here spins excessively and lands the
      // change at ill-timed points (IFU M-mode straddle). The stimulus
      // sequences already drain each privilege batch (per-batch fork/join)
      // before changing priv, so no in-flight access straddles the change.
      // wait_for_mmu_idle() remains available for the dynamic-satp milestone,
      // which genuinely needs a quiescent MMU to swap the translation context.
      // Update the held level pins (persist until the next CTX_SET).
      vif.csr_drv_cb.cp0_yy_priv_mode <= item.priv_mode;
      vif.csr_drv_cb.cp0_mmu_mprv     <= item.mprv;
      vif.csr_drv_cb.cp0_mmu_mpp      <= item.mpp;
      vif.csr_drv_cb.cp0_mmu_mxr      <= item.mxr;
      vif.csr_drv_cb.cp0_mmu_sum      <= item.sum;
      vif.csr_drv_cb.cp0_mmu_ptw_en   <= item.ptw_en;
      vif.csr_drv_cb.cp0_mmu_maee     <= item.maee;
      vif.csr_drv_cb.cp0_mmu_cskyee   <= item.cskyee;
      // Settle before returning so the level pins are stable before the caller
      // issues the next stimulus batch. The pins register on the next edge and
      // the TLBs have request->response latency, so without this an access
      // issued right after the change can be translated by the DUT under the
      // OLD priv while the monitor samples the NEW priv (a priv straddle -> e.g.
      // false IFU M-mode-bypass mismatches). A small fixed gap is enough and,
      // unlike gating on mmu_yy_xx_no_op, never spins during steady traffic.
      repeat (8) @(vif.csr_drv_cb);
    end
    else if (item.op == mmu_csr_seq_item::REG_READ) begin
      // Select the register and sample; mmu_cp0_data is combinational off
      // reg_num, so no write strobe and no completion handshake.
      vif.csr_drv_cb.cp0_mmu_wreg    <= 1'b0;
      vif.csr_drv_cb.cp0_mmu_reg_num <= sel2regnum(item.sel);
      @(vif.csr_drv_cb);
      item.rdata = (item.sel == mmu_csr_seq_item::SATP)
                     ? vif.csr_drv_cb.mmu_cp0_satp_data
                     : vif.csr_drv_cb.mmu_cp0_data;
      vif.csr_drv_cb.cp0_mmu_reg_num <= '0;
    end
    else begin // REG_WRITE — pulse the write; it registers on the clock edge.
      vif.csr_drv_cb.cp0_mmu_wdata <= item.wdata;
      vif.csr_drv_cb.cp0_mmu_wreg  <= 1'b1;
      if (item.sel == mmu_csr_seq_item::SATP) begin
        vif.csr_drv_cb.cp0_mmu_satp_sel <= 1'b1;
        vif.csr_drv_cb.cp0_mmu_reg_num  <= '0;
      end
      else begin
        vif.csr_drv_cb.cp0_mmu_satp_sel <= 1'b0;
        vif.csr_drv_cb.cp0_mmu_reg_num  <= sel2regnum(item.sel);
      end
      @(vif.csr_drv_cb);                 // DUT registers the write here
      vif.csr_drv_cb.cp0_mmu_wreg     <= 1'b0;
      vif.csr_drv_cb.cp0_mmu_satp_sel <= 1'b0;
      vif.csr_drv_cb.cp0_mmu_reg_num  <= '0;
      vif.csr_drv_cb.cp0_mmu_wdata    <= '0;
    end
  endtask

  protected function bit [1:0] sel2regnum(mmu_csr_seq_item::csr_sel_e s);
    case (s)
      mmu_csr_seq_item::MIR : return REGNUM_MIR;
      mmu_csr_seq_item::MEL : return REGNUM_MEL;
      mmu_csr_seq_item::MEH : return REGNUM_MEH;
      mmu_csr_seq_item::MCIR: return REGNUM_MCIR;
      default               : return '0;
    endcase
  endfunction

endclass : mmu_csr_driver

`endif // MMU_CSR_DRIVER_SV
