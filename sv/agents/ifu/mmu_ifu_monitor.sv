// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_ifu_monitor.sv
//
// Passive monitor for the IFU translation agent. Samples ifu_mon_cb and
// publishes one mmu_ifu_seq_item per completed translation on `ap`.
//
// Pairing: the C910 IFU port has NO request ID. mmu_ifu_pavld/pa/pgflt/ca/sec/
// buf are combinational off the current lookup (RTL: ct_mmu_iutlb.v), so the
// response on any cycle belongs to whatever VA is on ifu_mmu_va THAT cycle. We
// capture those on every cycle mmu_ifu_pavld==1 (LEVEL, not rising edge) keyed
// by the same-cycle ifu_mmu_va, supporting back-to-back 1/cycle hits.
//
// mmu_ifu_deny is the exception: it is REGISTERED (jtlb_acc_fault_flop), so a
// fetch's deny appears one cycle AFTER its va/pa. We therefore hold each
// captured fetch one cycle and fill in deny (then publish) on the next cycle,
// so the access fault is attributed to the fetch that actually caused it.
//======================================================================
`ifndef MMU_IFU_MONITOR_SV
`define MMU_IFU_MONITOR_SV

class mmu_ifu_monitor extends uvm_monitor;
  `uvm_component_utils(mmu_ifu_monitor)

  virtual mmu_if                     vif;
  uvm_analysis_port #(mmu_ifu_seq_item) ap;

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
    mmu_ifu_seq_item pend;          // fetch captured last cycle, awaiting its deny
    bit              pend_vld = 1'b0;
    forever begin
      @(vif.ifu_mon_cb);

      // Complete the fetch captured on the PREVIOUS cycle: mmu_ifu_deny is
      // registered (jtlb_acc_fault_flop), so it is presented one cycle after
      // that fetch's combinational va/pa/pgflt. Attribute the deny sampled
      // THIS cycle to that prior fetch, then publish it.
      if (pend_vld) begin
        // A privilege change landing on THIS cycle makes the deny unattributable:
        // the MMU output already reflects the new context while pend was captured
        // under the old one, so the deny belongs to a different translation
        // regime. A bypass captured with pgflt=0/deny=0 can otherwise pick up a
        // deny that rises in the same instant priv changes, scoring a false
        // access fault. Drop rather than mis-score.
        if (vif.ifu_mon_cb.cp0_yy_priv_mode !== pend.priv_mode) begin
          `uvm_info(get_type_name(),
            $sformatf("dropping fetch va=0x%0h: priv changed %0d->%0d before its registered deny",
                      pend.va, pend.priv_mode, vif.ifu_mon_cb.cp0_yy_priv_mode), UVM_MEDIUM)
        end
        else begin
          pend.deny = vif.ifu_mon_cb.mmu_ifu_deny;
          ap.write(pend);
          `uvm_info(get_type_name(), pend.convert2string(), UVM_HIGH)
        end
        pend_vld  = 1'b0;
      end

      // Capture a new response this cycle (mmu_ifu_pavld==1) for a valid,
      // non-abort request, keyed by the same-cycle ifu_mmu_va. Its deny is
      // filled in next cycle (registered output). Back-to-back 1/cycle hits
      // each produce their own transaction.
      if (vif.ifu_mon_cb.mmu_ifu_pavld  === 1'b1 &&
          vif.ifu_mon_cb.ifu_mmu_va_vld === 1'b1 &&
          vif.ifu_mon_cb.ifu_mmu_abort  !== 1'b1) begin
        pend            = mmu_ifu_seq_item::type_id::create("tr");
        pend.va         = vif.ifu_mon_cb.ifu_mmu_va;   // same-cycle VA (the key)
        pend.abort      = 1'b0;
        pend.pa         = vif.ifu_mon_cb.mmu_ifu_pa;
        pend.pavld      = 1'b1;
        pend.pgflt      = vif.ifu_mon_cb.mmu_ifu_pgflt;
        pend.ca         = vif.ifu_mon_cb.mmu_ifu_ca;
        pend.sec        = vif.ifu_mon_cb.mmu_ifu_sec;
        pend.bufferable = vif.ifu_mon_cb.mmu_ifu_buf;
        pend.priv_mode  = vif.ifu_mon_cb.cp0_yy_priv_mode;  // fetch-cycle privilege
        pend.sum        = vif.ifu_mon_cb.cp0_mmu_sum;       // C910: SUM gates fetch too
        pend_vld        = 1'b1;
      end
    end
  endtask

endclass : mmu_ifu_monitor

`endif // MMU_IFU_MONITOR_SV
