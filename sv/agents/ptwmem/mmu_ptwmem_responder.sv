// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_ptwmem_responder.sv
//
// Active responder for the PTW memory bus. The DUT (page-table walker)
// requests 8-byte PTE reads on mmu_lsu_data_req/addr; this component
// returns the data from the shared mmu_sysmem on lsu_mmu_data/vld.
//
// Behaviour: 1-cycle fixed latency, no bus errors, single outstanding
// (the PTW FSM issues one PTE read at a time). Gets the shared mmu_vif and
// mem_model from the config_db (per house style).
//======================================================================

`ifndef MMU_PTWMEM_RESPONDER_SV
`define MMU_PTWMEM_RESPONDER_SV

class mmu_ptwmem_responder extends uvm_component;
  `uvm_component_utils(mmu_ptwmem_responder)

  virtual mmu_if       vif;
  mmu_common_pkg::mmu_sysmem mem;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual mmu_if)::get(this, "", "mmu_vif", vif))
      `uvm_fatal(get_type_name(), "mmu_vif not found in config DB")
    if (!uvm_config_db#(mmu_common_pkg::mmu_sysmem)::get(this, "", "mmu_mem", mem))
      `uvm_fatal(get_type_name(), "mmu_mem not found in config DB")
  endfunction

  task run_phase(uvm_phase phase);
    drive_idle();
    wait (vif.cpurst_b === 1'b1);
    forever begin
      @(vif.ptwmem_drv_cb);
      if (vif.ptwmem_drv_cb.mmu_lsu_data_req === 1'b1) begin
        longint unsigned addr = vif.ptwmem_drv_cb.mmu_lsu_data_req_addr;
        longint unsigned data = mem.read_8(addr);
        // Respond next cycle with the PTE.
        @(vif.ptwmem_drv_cb);
        vif.ptwmem_drv_cb.lsu_mmu_data      <= data;
        vif.ptwmem_drv_cb.lsu_mmu_data_vld  <= 1'b1;
        vif.ptwmem_drv_cb.lsu_mmu_bus_error <= 1'b0;
        `uvm_info(get_type_name(),
          $sformatf("PTE read addr=0x%0h -> data=0x%0h", addr, data), UVM_HIGH)
        @(vif.ptwmem_drv_cb);
        drive_idle();
      end
    end
  endtask

  protected task drive_idle();
    vif.ptwmem_drv_cb.lsu_mmu_data      <= '0;
    vif.ptwmem_drv_cb.lsu_mmu_data_vld  <= 1'b0;
    vif.ptwmem_drv_cb.lsu_mmu_bus_error <= 1'b0;
  endtask

endclass : mmu_ptwmem_responder

`endif // MMU_PTWMEM_RESPONDER_SV
