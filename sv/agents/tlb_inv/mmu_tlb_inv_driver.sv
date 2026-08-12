// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_tlb_inv_driver.sv
//
// Drives one TLB-invalidation at a time on the LSU-side maintenance pins
// (sfence.vma) or the CP0 full-flush pin. Per item:
//   * assert the matching strobe (+ va/asid operands) held,
//   * wait for the single-cycle mmu_lsu_tlb_inv_done pulse (INVALL walks 256
//     sets, INVASID walks 1024 entries -> multi-cycle; VA is a bounded sweep),
//   * deassert, then a settle so the tlboper FSM returns to idle before the
//     next request (the RTL serializes on tlb_sm_idle).
// One invalidation in flight at a time -- the DUT has a single maintenance FSM.
//======================================================================
`ifndef MMU_TLB_INV_DRIVER_SV
`define MMU_TLB_INV_DRIVER_SV

class mmu_tlb_inv_driver extends uvm_driver #(mmu_tlb_inv_seq_item);
  `uvm_component_utils(mmu_tlb_inv_driver)

  virtual mmu_if vif;

  // Bound for the done wait: an all-invalidate walks 256 sets / INVASID 1024
  // entries, tens-to-hundreds of cycles; huge so it fails loud, never hangs.
  localparam int unsigned WATCHDOG_CYCLES = 20000;
  // Settle after done so tlb_sm_idle is re-established before the next request.
  localparam int unsigned SETTLE_CYCLES   = 4;

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
    @(vif.inv_drv_cb);
    forever begin
      seq_item_port.get_next_item(req);
      drive_inv(req);
      seq_item_port.item_done();
    end
  endtask

  protected task drive_idle();
    vif.inv_drv_cb.lsu_mmu_tlb_all_inv      <= 1'b0;
    vif.inv_drv_cb.lsu_mmu_tlb_asid         <= 16'b0;
    vif.inv_drv_cb.lsu_mmu_tlb_asid_all_inv <= 1'b0;
    vif.inv_drv_cb.lsu_mmu_tlb_va           <= 27'b0;
    vif.inv_drv_cb.lsu_mmu_tlb_va_all_inv   <= 1'b0;
    vif.inv_drv_cb.lsu_mmu_tlb_va_asid_inv  <= 1'b0;
    vif.inv_drv_cb.cp0_mmu_tlb_all_inv      <= 1'b0;
  endtask

  protected task drive_inv(mmu_tlb_inv_seq_item item);
    int unsigned c;

    // Present the operands + the matching strobe (held until done).
    vif.inv_drv_cb.lsu_mmu_tlb_asid <= item.asid;
    vif.inv_drv_cb.lsu_mmu_tlb_va   <= item.vpn;
    case (item.kind)
      INV_ALL:     vif.inv_drv_cb.lsu_mmu_tlb_all_inv      <= 1'b1;
      INV_ASID:    vif.inv_drv_cb.lsu_mmu_tlb_asid_all_inv <= 1'b1;
      INV_VA:      vif.inv_drv_cb.lsu_mmu_tlb_va_all_inv   <= 1'b1;
      INV_VA_ASID: vif.inv_drv_cb.lsu_mmu_tlb_va_asid_inv  <= 1'b1;
      INV_CP0_ALL: vif.inv_drv_cb.cp0_mmu_tlb_all_inv      <= 1'b1;
    endcase

    // Wait for the completion pulse. The CP0/SMCIR full-flush completes on
    // mmu_cp0_tlb_done (=tlb_invall_cmplt); the LSU-path sfence variants complete
    // on mmu_lsu_tlb_inv_done (=lsu_oper_cmplt). They are distinct RTL signals.
    c = 0;
    @(vif.inv_drv_cb);
    if (item.kind == INV_CP0_ALL) begin
      while (vif.inv_drv_cb.mmu_cp0_tlb_done !== 1'b1) begin
        if (++c > WATCHDOG_CYCLES) begin
          `uvm_error(get_type_name(),
            $sformatf("no mmu_cp0_tlb_done within %0d cycles for %s",
                      WATCHDOG_CYCLES, item.kind.name()))
          break;
        end
        @(vif.inv_drv_cb);
      end
    end
    else begin
      while (vif.inv_drv_cb.mmu_lsu_tlb_inv_done !== 1'b1) begin
        if (++c > WATCHDOG_CYCLES) begin
          `uvm_error(get_type_name(),
            $sformatf("no mmu_lsu_tlb_inv_done within %0d cycles for %s",
                      WATCHDOG_CYCLES, item.kind.name()))
          break;
        end
        @(vif.inv_drv_cb);
      end
    end

    // Deassert + settle so the maintenance FSM returns to idle.
    drive_idle();
    repeat (SETTLE_CYCLES) @(vif.inv_drv_cb);
  endtask

endclass : mmu_tlb_inv_driver

`endif // MMU_TLB_INV_DRIVER_SV
