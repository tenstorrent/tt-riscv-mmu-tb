// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_tlb_inv_test.sv
//
// TLB-invalidation test: drives sfence.vma variants + the CP0 full flush while
// IFU/LSU translation traffic runs CONCURRENTLY. The env's
// mmu_invalidation_checker backdoor-reads the TLBs after each done pulse and
// asserts the flush semantics (global survives ASID in the jTLB, uTLB coarse
// flush, VA page-size masking, ...).
//
// The test forks its fetch, data
// and invalidation sequences in parallel:
//   1) run ONE setup sequence to completion (page tables -> sysmem+Whisper ->
//      satp -> PMP) and capture the generated context;
//   2) fork IFU traffic + LSU traffic + the invalidation stream on the same
//      virtual sequencer, handing each the captured context with skip_setup;
//   3) clear mmu_tlb_inv_seq::traffic_active when the traffic threads finish so
//      the invalidation loop stops instead of flushing an idle MMU.
//
// Concurrency is the point: it keeps the TLBs populated (so every flush has live
// entries to verify -- see the checker's live-entry witness) and lets flushes
// land while translations are in flight.
//
// The LSU sequence owns the shared privilege pin (switch_priv=1); the IFU must
// not drive it (switch_priv=0) or the two race on it.
//======================================================================
`ifndef MMU_TLB_INV_TEST_SV
`define MMU_TLB_INV_TEST_SV

class mmu_tlb_inv_test extends mmu_base_test;
  `uvm_component_utils(mmu_tlb_inv_test)

  // Traffic volume driven alongside the invalidations. Traffic has its own fixed
  // budget and never waits on the invalidation stream (the dependency
  // direction: the stream yields when traffic ends), so this sizing is what
  // determines how many invalidations actually fit.
  //   ~0.45us per request, gap ~13.7us average per flush
  //   => 150 flushes need ~2.05ms of traffic => ~4500 requests
  // 4000 covers the 50-150 range with margin; the sequence warns if a seed still
  // undershoots. Override with +MMU_INV_TRAFFIC_REQS=<n>.
  int unsigned traffic_reqs = 4000;

  function new(string name = "mmu_tlb_inv_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    mmu_base_seq     setup;
    mmu_ifu_seq      ifu;
    mmu_lsu_seq      lsu;
    mmu_tlb_inv_seq  inv;

    phase.raise_objection(this, "tlb inv");
    phase.phase_done.set_drain_time(this, 200ns);

    // This test keeps IFU/LSU traffic running alongside every flush, so the CAM
    // sweep must always find live entries. Escalate a zero witness to an error
    // here (opt-in: other tests flush at context boundaries where zero survivors
    // is legitimate).
    env.inv_chk.require_live_entries = 1'b1;

    void'($value$plusargs("MMU_INV_TRAFFIC_REQS=%d", traffic_reqs));

    // 1) One-time setup: build the page tables, preload sysmem+Whisper, program
    //    satp and PMP. Base drive_stimulus() is a no-op, so this just sets up.
    setup = mmu_base_seq::type_id::create("inv_setup");
    setup.start(env.vseqr);

    // 2) Traffic + invalidations, concurrently. Children skip setup and inherit
    //    the context the setup sequence generated.
    ifu = mmu_ifu_seq::type_id::create("inv_traf_ifu");
    lsu = mmu_lsu_seq::type_id::create("inv_traf_lsu");
    inv = mmu_tlb_inv_seq::type_id::create("inv_stream");

    ifu.skip_setup = 1'b1;  ifu.switch_priv = 1'b0;  ifu.num_of_reqs = traffic_reqs / 2;
    lsu.skip_setup = 1'b1;  lsu.switch_priv = 1'b1;  lsu.num_of_reqs = traffic_reqs;
    inv.skip_setup = 1'b1;

    ifu.va_entries = setup.va_entries;  ifu.satp_ppn = setup.satp_ppn;  ifu.satp_mode = setup.satp_mode;
    lsu.va_entries = setup.va_entries;  lsu.satp_ppn = setup.satp_ppn;  lsu.satp_mode = setup.satp_mode;
    inv.va_entries = setup.va_entries;  inv.satp_ppn = setup.satp_ppn;  inv.satp_mode = setup.satp_mode;
    inv.gen_asid   = setup.gen_asid;    // so INV_ASID targets the live ASID

    mmu_tlb_inv_seq::traffic_active = 1'b1;
    fork
      begin   // traffic; clears the flag when both pipes are done
        fork
          ifu.start(env.vseqr);
          lsu.start(env.vseqr);
        join
        mmu_tlb_inv_seq::traffic_active = 1'b0;
        `uvm_info(get_type_name(), "IFU/LSU traffic complete", UVM_LOW)
      end
      inv.start(env.vseqr);
    join

    phase.drop_objection(this, "tlb inv done");
  endtask

endclass : mmu_tlb_inv_test

`endif // MMU_TLB_INV_TEST_SV
