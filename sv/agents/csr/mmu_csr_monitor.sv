// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_csr_monitor.sv
//
// Passive monitor for the CSR / CP0 agent. Emits one mmu_csr_seq_item per
// register write (rising cp0_mmu_wreg | cp0_mmu_satp_sel) on `ap`,
// reconstructing sel from satp_sel/reg_num and capturing wdata, the cmplt
// ack, the readback (satp_data or cp0_data), and mmu_xx_mmu_en.
//======================================================================
`ifndef MMU_CSR_MONITOR_SV
`define MMU_CSR_MONITOR_SV

class mmu_csr_monitor extends uvm_monitor;
  `uvm_component_utils(mmu_csr_monitor)

  virtual mmu_if                         vif;
  uvm_analysis_port #(mmu_csr_seq_item)  ap;

  protected logic prev_wr;   // previous (wreg | satp_sel) for rising-edge detect

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual mmu_if)::get(this, "", "mmu_vif", vif))
      `uvm_fatal(get_type_name(), "mmu_vif not found in config DB")
  endfunction

  task run_phase(uvm_phase phase);
    mmu_csr_seq_item tr;
    logic            wr;
    prev_wr = 1'b0;
    forever begin
      @(vif.csr_mon_cb);
      wr = vif.csr_mon_cb.cp0_mmu_wreg | vif.csr_mon_cb.cp0_mmu_satp_sel;
      if (wr === 1'b1 && prev_wr !== 1'b1) begin
        tr        = mmu_csr_seq_item::type_id::create("tr");
        tr.op     = mmu_csr_seq_item::REG_WRITE;
        tr.sel    = (vif.csr_mon_cb.cp0_mmu_satp_sel === 1'b1)
                      ? mmu_csr_seq_item::SATP
                      : regnum2sel(vif.csr_mon_cb.cp0_mmu_reg_num);
        tr.wdata  = vif.csr_mon_cb.cp0_mmu_wdata;
        tr.cmplt  = vif.csr_mon_cb.mmu_cp0_cmplt;
        tr.rdata  = (tr.sel == mmu_csr_seq_item::SATP)
                      ? vif.csr_mon_cb.mmu_cp0_satp_data
                      : vif.csr_mon_cb.mmu_cp0_data;
        tr.mmu_en = vif.csr_mon_cb.mmu_xx_mmu_en;
        ap.write(tr);
        `uvm_info(get_type_name(), tr.convert2string(), UVM_HIGH)
      end
      prev_wr = wr;
    end
  endtask

  protected function mmu_csr_seq_item::csr_sel_e regnum2sel(bit [1:0] n);
    case (n)
      2'd0:    return mmu_csr_seq_item::MIR;
      2'd1:    return mmu_csr_seq_item::MEL;
      2'd2:    return mmu_csr_seq_item::MEH;
      default: return mmu_csr_seq_item::MCIR;
    endcase
  endfunction

endclass : mmu_csr_monitor

`endif // MMU_CSR_MONITOR_SV
