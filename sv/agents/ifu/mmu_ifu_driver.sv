// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_ifu_driver.sv
//
// Active driver for the IFU (instruction-fetch) translation agent.
//
// Drives fetch requests on ifu_drv_cb. The C910 IFU port is a same-cycle
// lookup with no request ID: a hit returns mmu_ifu_pavld the same cycle the VA
// is on the bus; a miss holds pavld low until the jTLB/PTW refill lands, after
// which (with the VA still on the bus) it hits and pavld asserts.
//
// PIPELINED driving: keep ifu_mmu_va_vld asserted across requests and present
// the next VA on the very cycle the current one completes — so a stream of
// hits flows back-to-back at 1/cycle. A miss simply holds its VA until pavld
// (the walk is the single serialization point). The port is only dropped when
// the sequence has no item ready (try_next_item == null), which keeps a stale
// VA from generating spurious lookups/monitor emits at end of stream.
//
// Response capture into the item is kept for the sequence's own self-check;
// the MONITOR is the authoritative observer for scoreboarding.
//======================================================================
`ifndef MMU_IFU_DRIVER_SV
`define MMU_IFU_DRIVER_SV

// Capture the fetch response into the seq item so the sequence can self-check
// (the monitor remains the authoritative observer for scoreboarding). Needed on
// two paths -- the speculative fast hit and the normal wait -- so the field list
// lives here once. Text substitution only, no handle-passing indirection.
// Undefined at the end of the file.
`define MMU_IFU_CAPTURE_RESP(ITEM)                     \
  ITEM.pa         = vif.ifu_drv_cb.mmu_ifu_pa;         \
  ITEM.pgflt      = vif.ifu_drv_cb.mmu_ifu_pgflt;      \
  ITEM.deny       = vif.ifu_drv_cb.mmu_ifu_deny;       \
  ITEM.ca         = vif.ifu_drv_cb.mmu_ifu_ca;         \
  ITEM.sec        = vif.ifu_drv_cb.mmu_ifu_sec;        \
  ITEM.bufferable = vif.ifu_drv_cb.mmu_ifu_buf;

class mmu_ifu_driver extends uvm_driver #(mmu_ifu_seq_item);
  `uvm_component_utils(mmu_ifu_driver)

  virtual mmu_if         vif;
  virtual mmu_tlb_bd_if  bd;    // refill-FSM probe for the post-fault drain

  // Safety net: a stuck request fails loudly instead of hanging sim during
  // bring-up. NOT a latency model (miss latency is open-ended per the doc);
  // a real walk is tens of cycles, so this is deliberately huge.
  localparam int unsigned WATCHDOG_CYCLES = 100000;

  // Speculative window: how long a speculative request waits for pavld before
  // being abandoned. A hit resolves within 1 cycle; a miss (walk) does not, so
  // this cleanly abandons only the miss case (models a front-end flow change).
  localparam int unsigned SPEC_WINDOW = 3;

  // Max cycles to drain a post-fault transient (ref FSM PGFLT->IDLE + registered
  // deny clear). Tiny on purpose -- see drain-after-fault below.
  localparam int unsigned DRAIN_MAX = 64;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual mmu_if)::get(this, "", "mmu_vif", vif))
      `uvm_fatal(get_type_name(), "mmu_vif not found in config DB")
    if (!uvm_config_db#(virtual mmu_tlb_bd_if)::get(this, "", "tlb_bd_vif", bd))
      `uvm_fatal(get_type_name(), "tlb_bd_vif not found in config DB (post-fault drain needs it)")
  endfunction

  task run_phase(uvm_phase phase);
    drive_idle();
    wait (vif.cpurst_b === 1'b1);          // hold off until reset released
    @(vif.ifu_drv_cb);
    forever begin
      // Non-blocking pull so the port can idle cleanly when the stream is
      // drained, and drive back-to-back when items are ready.
      seq_item_port.try_next_item(req);
      if (req == null) begin
        drive_idle();
        @(vif.ifu_drv_cb);
        continue;
      end
      drive_req(req);
      seq_item_port.item_done();
    end
  endtask

  // Hold the request lines inactive.
  protected task drive_idle();
    vif.ifu_drv_cb.ifu_mmu_va     <= '0;
    vif.ifu_drv_cb.ifu_mmu_va_vld <= 1'b0;
    vif.ifu_drv_cb.ifu_mmu_abort  <= 1'b0;
  endtask

  protected task drive_req(mmu_ifu_seq_item item);
    int unsigned cyc;

    if (item.abort) begin
      // Abort path: pulse the request with abort; no pavld is expected.
      vif.ifu_drv_cb.ifu_mmu_va     <= item.va;
      vif.ifu_drv_cb.ifu_mmu_va_vld <= 1'b1;
      vif.ifu_drv_cb.ifu_mmu_abort  <= 1'b1;
      @(vif.ifu_drv_cb);
      drive_idle();
      @(vif.ifu_drv_cb);
      return;
    end

    // Speculative path: present the VA; if it does not resolve within a short
    // window (i.e. it missed and a walk started), ABANDON it via ifu_mmu_abort
    // — modelling a front-end flow change. The RTL owes no response for an
    // abandoned fetch, so no pavld is expected/captured.
    if (item.speculative) begin
      vif.ifu_drv_cb.ifu_mmu_va     <= item.va;
      vif.ifu_drv_cb.ifu_mmu_va_vld <= 1'b1;
      vif.ifu_drv_cb.ifu_mmu_abort  <= 1'b0;
      for (cyc = 0; cyc < SPEC_WINDOW; cyc++) begin
        @(vif.ifu_drv_cb);
        if (vif.ifu_drv_cb.mmu_ifu_pavld === 1'b1) begin
          // Hit (or fast completion): capture and finish normally.
          `MMU_IFU_CAPTURE_RESP(item)
          item.pavld = 1'b1;
          return;
        end
      end
      // Missed within the window -> abandon (assert abort for one cycle).
      vif.ifu_drv_cb.ifu_mmu_abort  <= 1'b1;
      @(vif.ifu_drv_cb);
      drive_idle();
      @(vif.ifu_drv_cb);
      item.abandoned = 1'b1;
      item.pavld     = 1'b0;
      return;
    end

    // Normal path: present the VA (keep va_vld asserted from any prior request)
    // and hold THIS VA until its pavld. On a hit pavld lands next cycle
    // (1/cycle back-to-back); on a miss the same VA stays on the bus until the
    // refill completes and it hits.
    vif.ifu_drv_cb.ifu_mmu_va     <= item.va;
    vif.ifu_drv_cb.ifu_mmu_va_vld <= 1'b1;
    vif.ifu_drv_cb.ifu_mmu_abort  <= 1'b0;

    cyc = 0;
    @(vif.ifu_drv_cb);
    while (vif.ifu_drv_cb.mmu_ifu_pavld !== 1'b1) begin
      if (++cyc > WATCHDOG_CYCLES) begin
        `uvm_error(get_type_name(),
          $sformatf("no mmu_ifu_pavld within %0d cycles for VA=0x%0h", WATCHDOG_CYCLES, item.va))
        break;
      end
      @(vif.ifu_drv_cb);
    end

    item.pavld = vif.ifu_drv_cb.mmu_ifu_pavld;
    `MMU_IFU_CAPTURE_RESP(item)

    // A fetch that went through the walk (miss, cyc>0) or that faulted can leave
    // a fault indication asserted into the next fetch's window.
    if (cyc > 0 || vif.ifu_drv_cb.mmu_ifu_pgflt === 1'b1 || vif.ifu_drv_cb.mmu_ifu_deny === 1'b1)
      drain_after_walk();

    // NOTE: do NOT drive_idle on the clean path — leaving va_vld asserted lets
    // the next request take the bus immediately (back-to-back). The run loop
    // idles the port only when no item is ready.
  endtask

  //--------------------------------------------------------------------
  // Drain the post-walk fault window (real IFU behavior, not a stimulus
  // constraint). The C910 iuTLB refill is BLOCKING and leaves two fault
  // indications OR'd into the fetch outputs WITHOUT the !iutlb_off_hit gate:
  //   * mmu_ifu_pgflt <- iutlb_ref_pgflt (ref FSM==PGFLT), COMBINATIONAL
  //   * mmu_ifu_deny  <- jtlb_acc_fault_flop, REGISTERED (one cycle late)
  // Presenting the next VA into that window makes its bypass response inherit
  // the prior fetch's fault. Real HW serializes here (blocking refill + IFU
  // abort/redirect), so drop the port, advance one cycle for the registered
  // deny, then wait for the refill FSM to settle. Hits (cyc==0) cannot leave a
  // walk fault and stay back-to-back, so no coverage is lost.
  //
  // Probe the refill FSM via the backdoor, NOT mmu_ifu_pgflt: with the port idle
  // in S/U mode flg_fin==0 => V=0, so pgflt reads 1 forever and polling it can
  // only time out. DRAIN_MAX is therefore just a safety net.
  //--------------------------------------------------------------------
  protected task drain_after_walk();
    int unsigned d = 0;
    // Release the port via ifu_mmu_abort, not a bare deassert. The iuTLB can
    // answer a fetch AND start a refill in the same cycle (e.g. a non-canonical
    // VA: va_illegal + pavld + pgflt, with iutlb_miss_vld also set). Dropping
    // ifu_mmu_va_vld then leaves that refill in WFG with no VA behind it, and
    // because iutlb_arb_vpn is combinational off ifu_mmu_va the walk latches
    // zero at arbiter-grant time -- a VPN-0 walk whose page fault is owned by no
    // request. ifu_mmu_abort is what cancels it (WFG + abort -> IDLE); the
    // speculative-abandon path above already does this.
    vif.ifu_drv_cb.ifu_mmu_abort <= 1'b1;
    @(vif.ifu_drv_cb);
    drive_idle();            // release the port (models abort/redirect)
    @(vif.ifu_drv_cb);       // let the registered deny appear
    while (!bd.iutlb_fault_settled() && d < DRAIN_MAX) begin
      @(vif.ifu_drv_cb);
      d++;
    end
  endtask

endclass : mmu_ifu_driver

`undef MMU_IFU_CAPTURE_RESP

`endif // MMU_IFU_DRIVER_SV
