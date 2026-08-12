// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_env.sv
//
// Top-level UVM environment for the OpenC910 MMU testbench. It builds the
// per-interface agents (IFU, LSU, CSR, PTW-memory, PMP, TLB-invalidation),
// the shared memory model, the Whisper reference model and the scoreboards.
//
// Every agent is active by default, and each driver/monitor fetches the
// shared mmu_vif from the config_db itself, so the env only constructs them.
//======================================================================

`ifndef MMU_ENV_SV
`define MMU_ENV_SV

class mmu_env extends uvm_env;
  `uvm_component_utils(mmu_env)

  mmu_ifu_agent    ifu_agt;
  mmu_lsu_agent    lsu_agt;
  mmu_csr_agent    csr_agt;
  mmu_ptwmem_agent ptwmem_agt;
  // PMP config-manager agent: drv writes each applied config into
  // mmu_if.pmp_cfg; mon.ap feeds the scoreboard.
  mmu_pmp_agent    pmp_agt;
  // TLB-invalidation (sfence.vma) agent + its whitebox checker.
  mmu_tlb_inv_agent        inv_agt;
  mmu_invalidation_checker inv_chk;

  // Shared LSU outstanding-id pool (LSQ/LSIQ stand-in): the LSU driver
  // allocates/frees ids; the stimulus back-pressures on it. Published on the
  // config_db for the driver and handed to the virtual sequencer.
  mmu_lsu_idbuf    idbuf;

  // Virtual sequencer: lets a virtual sequence (mmu_base_seq) reach the agent
  // sequencers + shared memory via p_sequencer. Wired in connect_phase.
  mmu_virtual_sequencer vseqr;

  // Shared DUT/TB physical memory (sysmem + mem-manager DPI). Published on the
  // config_db so the ptw_mem responder (and later the scoreboard) share one
  // instance; also handed to the virtual sequencer for the base seq's preload.
  mmu_sysmem       mem;

  // Whisper reference model + DUT-vs-Whisper scoreboard.
  whisper_dv_mmu   wh;
  mmu_scoreboard   sb;

  // MMU functional-coverage collector (subscribes to sb.xlate_ap). Always
  // instantiated; the covergroups are compiled in only with +define+MMU_COVERAGE
  // (otherwise the collector's write() is a no-op -- see mmu_coverage_pkg).
  mmu_cov_collector cov;

  // Whisper model memory bound. Must cover the C910 40-bit PA range — the
  // riescue page tables sit well above 4 GB, so the wrapper's 4 GB default is
  // too small (DvMmu treats pa >= mem_size as out-of-bounds). Memory is sparse,
  // so this is only an upper bound, not an allocation.
  localparam longint unsigned WHISPER_MEM_SIZE = 64'h100_0000_0000; // 2^40

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mem = mmu_sysmem::type_id::create("mem");
    uvm_config_db#(mmu_sysmem)::set(this, "*", "mmu_mem", mem);

    idbuf = mmu_lsu_idbuf::type_id::create("idbuf");
    uvm_config_db#(mmu_lsu_idbuf)::set(this, "*", "mmu_lsu_idbuf", idbuf);

    ifu_agt    = mmu_ifu_agent   ::type_id::create("ifu_agt", this);
    lsu_agt    = mmu_lsu_agent   ::type_id::create("lsu_agt", this);
    csr_agt    = mmu_csr_agent   ::type_id::create("csr_agt", this);
    ptwmem_agt = mmu_ptwmem_agent::type_id::create("ptwmem_agt", this);
    pmp_agt    = mmu_pmp_agent  ::type_id::create("pmp_agt", this);
    inv_agt    = mmu_tlb_inv_agent::type_id::create("inv_agt", this);
    inv_chk    = mmu_invalidation_checker::type_id::create("inv_chk", this);
    vseqr      = mmu_virtual_sequencer::type_id::create("vseqr", this);

    wh         = whisper_dv_mmu::type_id::create("wh", this);
    wh.mem_size = WHISPER_MEM_SIZE;   // sized before wh's connect_phase creates the C++ model
    sb         = mmu_scoreboard::type_id::create("sb", this);
    cov        = mmu_cov_collector::type_id::create("cov", this);
  endfunction

  // Wire the virtual sequencer to the agent sequencers + shared memory, the
  // scoreboard to the IFU monitor + Whisper, and the base-seq's Whisper handle.
  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    vseqr.csr_sqr  = csr_agt.sqr;
    vseqr.ifu_sqr  = ifu_agt.sqr;
    vseqr.lsu_sqr0 = lsu_agt.sqr0;
    vseqr.lsu_sqr1 = lsu_agt.sqr1;
    vseqr.pmp_sqr  = pmp_agt.sqr;
    vseqr.inv_sqr  = inv_agt.sqr;
    vseqr.mem      = mem;
    vseqr.idbuf   = idbuf;
    vseqr.wh      = wh;

    sb.wh = wh;
    ifu_agt.mon.ap.connect(sb.ifu_imp);
    lsu_agt.mon.ap.connect(sb.lsu_imp);
    // PMP config observer: every config the PMP agent applies
    // (the all-permissive default at reset, and any later test-driven
    // config) reaches the scoreboard, which programs Whisper from it.
    pmp_agt.mon.ap.connect(sb.pmp_imp);
    // TLB-invalidation monitor -> whitebox invalidation checker.
    inv_agt.mon.ap.connect(inv_chk.inv_imp);

    // Functional coverage: sample every resolved translation the scoreboard checks.
    sb.xlate_ap.connect(cov.analysis_export);
  endfunction

endclass : mmu_env

`endif // MMU_ENV_SV
