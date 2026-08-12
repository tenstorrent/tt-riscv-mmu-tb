// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_tlb_inv_monitor.sv
//
// Observes the TLB-maintenance pins. On the cycle a strobe first asserts,
// captures {kind, vpn, asid}; then counts cycles until the mmu_lsu_tlb_inv_done
// pulse and publishes the transaction (with done_latency) on ap. The checker
// backdoor-reads the TLBs on this publish to verify the flush.
//======================================================================
`ifndef MMU_TLB_INV_MONITOR_SV
`define MMU_TLB_INV_MONITOR_SV

class mmu_tlb_inv_monitor extends uvm_monitor;
  `uvm_component_utils(mmu_tlb_inv_monitor)

  virtual mmu_if vif;
  uvm_analysis_port #(mmu_tlb_inv_seq_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual mmu_if)::get(this, "", "mmu_vif", vif))
      `uvm_fatal(get_type_name(), "mmu_vif not found in config DB")
  endfunction

  // Which strobe (if any) is asserted this cycle -> kind. Returns 1 if a
  // request is present.
  protected function bit decode_kind(output mmu_inv_kind_e k);
    if      (vif.inv_mon_cb.lsu_mmu_tlb_all_inv      === 1'b1) k = INV_ALL;
    else if (vif.inv_mon_cb.lsu_mmu_tlb_asid_all_inv === 1'b1) k = INV_ASID;
    else if (vif.inv_mon_cb.lsu_mmu_tlb_va_all_inv   === 1'b1) k = INV_VA;
    else if (vif.inv_mon_cb.lsu_mmu_tlb_va_asid_inv  === 1'b1) k = INV_VA_ASID;
    else if (vif.inv_mon_cb.cp0_mmu_tlb_all_inv      === 1'b1) k = INV_CP0_ALL;
    else return 1'b0;
    return 1'b1;
  endfunction

  task run_phase(uvm_phase phase);
    mmu_inv_kind_e k;
    forever begin
      @(vif.inv_mon_cb);
      if (decode_kind(k)) begin
        mmu_tlb_inv_seq_item tr = mmu_tlb_inv_seq_item::type_id::create("tr");
        int unsigned lat = 0;
        tr.kind = k;
        tr.vpn  = vif.inv_mon_cb.lsu_mmu_tlb_va;
        tr.asid = vif.inv_mon_cb.lsu_mmu_tlb_asid;
        // Count to the done pulse. CP0 full-flush completes on mmu_cp0_tlb_done;
        // the LSU-path sfence variants on mmu_lsu_tlb_inv_done.
        if (k == INV_CP0_ALL) begin
          while (vif.inv_mon_cb.mmu_cp0_tlb_done !== 1'b1) begin
            @(vif.inv_mon_cb); lat++;
          end
        end
        else begin
          while (vif.inv_mon_cb.mmu_lsu_tlb_inv_done !== 1'b1) begin
            @(vif.inv_mon_cb); lat++;
          end
        end
        tr.done_latency = lat;
        ap.write(tr);
        `uvm_info(get_type_name(), tr.convert2string(), UVM_HIGH)
        // Skip past the strobe deassert so we don't re-capture the same request.
        while (decode_kind(k)) @(vif.inv_mon_cb);
      end
    end
  endtask

endclass : mmu_tlb_inv_monitor

`endif // MMU_TLB_INV_MONITOR_SV
