// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_lsu_driver.sv
//
// Active driver for the LSU (data) translation agent. Owns the pipe0/1 request
// pins (va/vld/id/st_inst/abort) on lsu_drv_cb.
//
// Dual-pipe: two worker threads (pipe0/pipe1), each fed by its own sequencer
// via its own pull port (seq_item_port -> pipe0, seq_item_port1 -> pipe1), so
// the two pipes drive concurrently without racing one port. Each access is
// presented and held until the DUT responds (hit | page_fault | access_fault),
// then captured back into the item.
//======================================================================
`ifndef MMU_LSU_DRIVER_SV
`define MMU_LSU_DRIVER_SV

class mmu_lsu_driver extends uvm_driver #(mmu_lsu_seq_item);
  `uvm_component_utils(mmu_lsu_driver)

  virtual mmu_if vif;
  mmu_lsu_idbuf  idbuf;

  // pipe1 gets its own pull port (the base seq_item_port feeds pipe0), so two
  // sequencers can feed the two pipe threads without racing a single port.
  uvm_seq_item_pull_port #(mmu_lsu_seq_item, mmu_lsu_seq_item) seq_item_port1;

  // Response wait bound: huge (a walk is tens of cycles) -- fails loud instead
  // of hanging the sim.
  localparam int unsigned WATCHDOG_CYCLES = 5000;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    seq_item_port1 = new("seq_item_port1", this);
    if (!uvm_config_db#(virtual mmu_if)::get(this, "", "mmu_vif", vif))
      `uvm_fatal(get_type_name(), "mmu_vif not found in config DB")
    if (!uvm_config_db#(mmu_lsu_idbuf)::get(this, "", "mmu_lsu_idbuf", idbuf))
      `uvm_fatal(get_type_name(), "mmu_lsu_idbuf not found in config DB")
  endfunction

  task run_phase(uvm_phase phase);
    drive_idle_all();
    wait (vif.cpurst_b === 1'b1);
    @(vif.lsu_drv_cb);
    fork
      drive_pipe(0);
      drive_pipe(1);
    join
  endtask

  // One pipe's worker: pull items from that pipe's sequencer and drive each to
  // completion (blocking, so the item's captured response is valid at item_done
  // and per-pipe completion is naturally tracked). Local `item` per thread — the
  // base driver's `req` member must NOT be shared across the two threads.
  protected task drive_pipe(int p);
    mmu_lsu_seq_item item;
    forever begin
      if (p == 0) seq_item_port.get_next_item(item);
      else        seq_item_port1.get_next_item(item);
      drive_access(p, item);
      if (p == 0) seq_item_port.item_done();
      else        seq_item_port1.item_done();
    end
  endtask

  // Drive one data access on pipe p: hold it presented (never park) until the
  // DUT responds. Holding keeps the compare-stage valid asserted (it is
  // combinational off vaN_vld, ct_mmu_dutlb.v:1367), so the duTLB's fault-
  // delivery handshake (dutlb_inst_id_match) fires the instant the shared refill
  // FSM hits PGFLT/ACFLT for this id -- parking could miss that window and
  // orphan the fault, wedging the FSM. Distinct in-flight id per access.
  protected task drive_access(int p, mmu_lsu_seq_item item);
    int id;
    bit got = 1'b0;

    id = idbuf.alloc();                 // distinct id per concurrent in-flight access
    if (id < 0)                         // <=1 outstanding per pipe -> pool never full
      `uvm_fatal(get_type_name(), "LSU id pool exhausted (expected <=1 outstanding/pipe)")
    item.pipe = p[1:0];
    item.id   = id[6:0];

    // Clean slate: access_fault is registered (jtlb_acc_fault_flop), so it lags
    // the previous access by a cycle. Drain it before issuing, else responded()
    // mis-reads it as THIS access's result and abandons the access early.
    begin
      int unsigned g = 0;
      while (responded(p) && g < WATCHDOG_CYCLES) begin @(vif.lsu_drv_cb); g++; end
    end

    present(p, item.va, item.st_inst, id);
    for (int unsigned c = 0; c < WATCHDOG_CYCLES && !got; c++) begin
      @(vif.lsu_drv_cb);
      if (responded(p)) got = 1'b1;
    end

    if (!got)
      `uvm_error(get_type_name(),
        $sformatf("no response for %s va=0x%0h id=%0d (pipe%0d)",
                  item.st_inst ? "ST" : "LD", item.va, id, p))

    capture(p, item);
    idbuf.free(id);
    drive_idle_pipe(p);
  endtask

  // ---- per-pipe pin helpers ----

  protected function bit responded(int p);
    if (p == 0)
      return (vif.lsu_drv_cb.mmu_lsu_pa0_vld       === 1'b1 ||
              vif.lsu_drv_cb.mmu_lsu_page_fault0   === 1'b1 ||
              vif.lsu_drv_cb.mmu_lsu_access_fault0 === 1'b1);
    else
      return (vif.lsu_drv_cb.mmu_lsu_pa1_vld       === 1'b1 ||
              vif.lsu_drv_cb.mmu_lsu_page_fault1   === 1'b1 ||
              vif.lsu_drv_cb.mmu_lsu_access_fault1 === 1'b1);
  endfunction

  protected task present(int p, bit [63:0] va, bit st, int id);
    if (p == 0) begin
      vif.lsu_drv_cb.lsu_mmu_va0      <= va;
      vif.lsu_drv_cb.lsu_mmu_va0_vld  <= 1'b1;
      vif.lsu_drv_cb.lsu_mmu_id0      <= id[6:0];
      vif.lsu_drv_cb.lsu_mmu_st_inst0 <= st;
      vif.lsu_drv_cb.lsu_mmu_abort0   <= 1'b0;
    end
    else begin
      vif.lsu_drv_cb.lsu_mmu_va1      <= va;
      vif.lsu_drv_cb.lsu_mmu_va1_vld  <= 1'b1;
      vif.lsu_drv_cb.lsu_mmu_id1      <= id[6:0];
      vif.lsu_drv_cb.lsu_mmu_st_inst1 <= st;
      vif.lsu_drv_cb.lsu_mmu_abort1   <= 1'b0;
    end
  endtask

  protected function void capture(int p, mmu_lsu_seq_item item);
    if (p == 0) begin
      item.pa           = vif.lsu_drv_cb.mmu_lsu_pa0;
      item.pa_vld       = vif.lsu_drv_cb.mmu_lsu_pa0_vld;
      item.page_fault   = vif.lsu_drv_cb.mmu_lsu_page_fault0;
      item.access_fault = vif.lsu_drv_cb.mmu_lsu_access_fault0;
      item.ca           = vif.lsu_drv_cb.mmu_lsu_ca0;
      item.sec          = vif.lsu_drv_cb.mmu_lsu_sec0;
      item.sh           = vif.lsu_drv_cb.mmu_lsu_sh0;
      item.so           = vif.lsu_drv_cb.mmu_lsu_so0;
      item.bufferable   = vif.lsu_drv_cb.mmu_lsu_buf0;
    end
    else begin
      item.pa           = vif.lsu_drv_cb.mmu_lsu_pa1;
      item.pa_vld       = vif.lsu_drv_cb.mmu_lsu_pa1_vld;
      item.page_fault   = vif.lsu_drv_cb.mmu_lsu_page_fault1;
      item.access_fault = vif.lsu_drv_cb.mmu_lsu_access_fault1;
      item.ca           = vif.lsu_drv_cb.mmu_lsu_ca1;
      item.sec          = vif.lsu_drv_cb.mmu_lsu_sec1;
      item.sh           = vif.lsu_drv_cb.mmu_lsu_sh1;
      item.so           = vif.lsu_drv_cb.mmu_lsu_so1;
      item.bufferable   = vif.lsu_drv_cb.mmu_lsu_buf1;
    end
  endfunction

  protected task drive_idle_pipe(int p);
    if (p == 0) begin
      vif.lsu_drv_cb.lsu_mmu_va0      <= '0;
      vif.lsu_drv_cb.lsu_mmu_va0_vld  <= 1'b0;
      vif.lsu_drv_cb.lsu_mmu_id0      <= '0;
      vif.lsu_drv_cb.lsu_mmu_st_inst0 <= 1'b0;
      vif.lsu_drv_cb.lsu_mmu_abort0   <= 1'b0;
    end
    else begin
      vif.lsu_drv_cb.lsu_mmu_va1      <= '0;
      vif.lsu_drv_cb.lsu_mmu_va1_vld  <= 1'b0;
      vif.lsu_drv_cb.lsu_mmu_id1      <= '0;
      vif.lsu_drv_cb.lsu_mmu_st_inst1 <= 1'b0;
      vif.lsu_drv_cb.lsu_mmu_abort1   <= 1'b0;
    end
  endtask

  protected task drive_idle_all();
    drive_idle_pipe(0);
    drive_idle_pipe(1);
  endtask

endclass : mmu_lsu_driver

`endif // MMU_LSU_DRIVER_SV
