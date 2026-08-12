// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_lsu_monitor.sv
//
// Passive monitor for the LSU (data) translation agent. Two independent
// per-pipe monitors sample lsu_mon_cb and publish one mmu_lsu_seq_item per
// completed translation on `ap`.
//
// Pairing (same rationale as the IFU monitor): the C910 LSU response is
// positional per pipe and carries no id. mmu_lsu_paN / paN_vld / page_faultN
// are combinational off the current lookup, so they belong to whatever VA is
// on lsu_mmu_vaN THAT cycle. We capture them keyed by the same-cycle VA on
// every cycle a response is presented (LEVEL, not rising edge) to catch
// back-to-back hits.
//
// mmu_lsu_access_faultN is the exception: it is REGISTERED (both its
// jtlb_acc_fault_flop term and its pmp_flg_vld-gated PMP terms are flopped --
// ct_mmu_dutlb_read.v:491-497), so a response's access fault appears one
// cycle AFTER its combinational va/pa/page_fault -- structurally identical to
// the IFU's registered mmu_ifu_deny. We therefore hold each captured response
// one cycle (per pipe, independently) and fill in access_fault from the NEXT
// cycle before publishing, so the fault is attributed to the response that
// actually caused it. pmp_flg_vld's enable (dutlb_pmp_chk_vld) includes
// dutlb_hit_vld, so the DUT DOES recheck PMP on a duTLB HIT -- the fault is
// real and one cycle late, not absent; a same-cycle sample simply missed it.
//======================================================================
`ifndef MMU_LSU_MONITOR_SV
`define MMU_LSU_MONITOR_SV

// Clocking-block field names cannot be selected by a runtime pipe index, so the
// two pipes' capture bodies are generated from one macro each. This keeps the
// field list in exactly ONE place (previously duplicated per pipe, so any new
// field had to be added in 2-4 spots). Text substitution only -- deliberately no
// helper-function/class-handle indirection, which Verilator mis-handles here.
// Undefined at the end of the file.
`define MMU_LSU_CAP_RESP(N)                                              \
  if (vif.lsu_mon_cb.lsu_mmu_va``N``_vld      === 1'b1 &&                 \
      (vif.lsu_mon_cb.mmu_lsu_pa``N``_vld     === 1'b1 ||                 \
       vif.lsu_mon_cb.mmu_lsu_page_fault``N`` === 1'b1)) begin            \
    tr            = mmu_lsu_seq_item::type_id::create("tr");              \
    tr.pipe       = 2'd``N;                                              \
    tr.va         = vif.lsu_mon_cb.lsu_mmu_va``N;    /* same-cycle key */ \
    tr.st_inst    = vif.lsu_mon_cb.lsu_mmu_st_inst``N;                    \
    tr.priv_mode  = vif.lsu_mon_cb.cp0_yy_priv_mode; /* eff priv in SB */ \
    tr.mprv       = vif.lsu_mon_cb.cp0_mmu_mprv;                          \
    tr.mpp        = vif.lsu_mon_cb.cp0_mmu_mpp;                           \
    tr.sum        = vif.lsu_mon_cb.cp0_mmu_sum;                           \
    tr.mxr        = vif.lsu_mon_cb.cp0_mmu_mxr;                           \
    tr.pa         = vif.lsu_mon_cb.mmu_lsu_pa``N;                         \
    tr.pa_vld     = vif.lsu_mon_cb.mmu_lsu_pa``N``_vld;                   \
    tr.page_fault = vif.lsu_mon_cb.mmu_lsu_page_fault``N;                 \
    tr.ca         = vif.lsu_mon_cb.mmu_lsu_ca``N;                         \
    tr.sec        = vif.lsu_mon_cb.mmu_lsu_sec``N;                        \
    tr.sh         = vif.lsu_mon_cb.mmu_lsu_sh``N;                         \
    tr.so         = vif.lsu_mon_cb.mmu_lsu_so``N;                         \
    tr.bufferable = vif.lsu_mon_cb.mmu_lsu_buf``N;                        \
  end

// Access-fault-only capture: access_fault asserted with no combinational
// pa_vld/page_fault (a walk aborted by a PMP/PMA deny). pa/page_fault invalid.
`define MMU_LSU_CAP_ACCFLT(N)                                            \
  if (vif.lsu_mon_cb.lsu_mmu_va``N``_vld       === 1'b1 &&                \
      vif.lsu_mon_cb.mmu_lsu_access_fault``N`` === 1'b1 &&                \
      vif.lsu_mon_cb.mmu_lsu_pa``N``_vld       !== 1'b1 &&                \
      vif.lsu_mon_cb.mmu_lsu_page_fault``N``   !== 1'b1) begin            \
    tr              = mmu_lsu_seq_item::type_id::create("tr");            \
    tr.pipe         = 2'd``N;                                            \
    tr.va           = vif.lsu_mon_cb.lsu_mmu_va``N;                       \
    tr.st_inst      = vif.lsu_mon_cb.lsu_mmu_st_inst``N;                  \
    tr.priv_mode    = vif.lsu_mon_cb.cp0_yy_priv_mode;                    \
    tr.mprv         = vif.lsu_mon_cb.cp0_mmu_mprv;                        \
    tr.mpp          = vif.lsu_mon_cb.cp0_mmu_mpp;                         \
    tr.sum          = vif.lsu_mon_cb.cp0_mmu_sum;                         \
    tr.mxr          = vif.lsu_mon_cb.cp0_mmu_mxr;                         \
    tr.pa_vld       = 1'b0;                                               \
    tr.page_fault   = 1'b0;                                               \
    tr.access_fault = 1'b1;                                               \
  end

class mmu_lsu_monitor extends uvm_monitor;
  `uvm_component_utils(mmu_lsu_monitor)

  virtual mmu_if                         vif;
  uvm_analysis_port #(mmu_lsu_seq_item)  ap;

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
    // Per-pipe response captured last cycle, awaiting its registered
    // access_fault. The two pipes are fully independent.
    mmu_lsu_seq_item pend0, pend1;
    bit              pend0_vld = 1'b0, pend1_vld = 1'b0;
    forever begin
      @(vif.lsu_mon_cb);

      // Complete each pipe's response captured on the PREVIOUS cycle:
      // mmu_lsu_access_faultN is registered, so it is presented one cycle
      // after that response's combinational va/pa/page_fault. Fill it from
      // THIS cycle and publish.
      if (pend0_vld) begin
        pend0.access_fault = vif.lsu_mon_cb.mmu_lsu_access_fault0;
        ap.write(pend0);
        `uvm_info(get_type_name(), pend0.convert2string(), UVM_HIGH)
        pend0_vld = 1'b0;
      end
      if (pend1_vld) begin
        pend1.access_fault = vif.lsu_mon_cb.mmu_lsu_access_fault1;
        ap.write(pend1);
        `uvm_info(get_type_name(), pend1.convert2string(), UVM_HIGH)
        pend1_vld = 1'b0;
      end

      // ACCESS-FAULT-ONLY response: a walk aborted by a PMP (or PMA) deny
      // raises the registered access_fault with NO combinational pa_vld/
      // page_fault cycle preceding it, so the pa_vld/page_fault trigger below
      // never fires and the response would be dropped. Capture it directly here
      // (access_fault is already asserted, key by the same-cycle VA) and
      // publish immediately. Guarded by !pend*_vld so we never double-count a
      // held pa_vld/page_fault response whose registered access_fault we just
      // filled above (those two cases never coincide -- access_fault is one
      // cycle after pa_vld/page_fault). capture_pipe*_accflt() only fires when
      // access_fault=1 and pa_vld=0 and page_fault=0.
      if (!pend0_vld) begin
        mmu_lsu_seq_item af0 = capture_pipe0_accflt();
        if (af0 != null) begin ap.write(af0); `uvm_info(get_type_name(), af0.convert2string(), UVM_HIGH) end
      end
      if (!pend1_vld) begin
        mmu_lsu_seq_item af1 = capture_pipe1_accflt();
        if (af1 != null) begin ap.write(af1); `uvm_info(get_type_name(), af1.convert2string(), UVM_HIGH) end
      end

      // Capture a new response this cycle on each pipe from the ON-TIME
      // (combinational) fields, keyed by the same-cycle VA. A response is
      // "present" when the PA is valid or a (combinational) page fault is
      // raised; access_fault is filled in next cycle (registered output).
      // Back-to-back 1/cycle hits each produce their own transaction.
      pend0     = capture_pipe0();
      pend0_vld = (pend0 != null);
      pend1     = capture_pipe1();
      pend1_vld = (pend1 != null);
    end
  endtask

  // Return an on-time-populated txn if the pipe presents a response this cycle,
  // else null. access_fault is left for the caller to fill next cycle.
  // tr.pipe MUST be exact: the scoreboard's PMP predictor keys pipe0's
  // always-on R-check (dutlb_ori_read0=1) on tr.pipe==0 (see mmu_lsu_seq_item).
  protected function mmu_lsu_seq_item capture_pipe0();
    mmu_lsu_seq_item tr;
    `MMU_LSU_CAP_RESP(0)
    return tr;   // null if no response this cycle
  endfunction

  protected function mmu_lsu_seq_item capture_pipe1();
    mmu_lsu_seq_item tr;
    `MMU_LSU_CAP_RESP(1)
    return tr;   // null if no response this cycle
  endfunction

  // Access-fault-only capture (see `MMU_LSU_CAP_ACCFLT above).
  protected function mmu_lsu_seq_item capture_pipe0_accflt();
    mmu_lsu_seq_item tr;
    `MMU_LSU_CAP_ACCFLT(0)
    return tr;
  endfunction

  protected function mmu_lsu_seq_item capture_pipe1_accflt();
    mmu_lsu_seq_item tr;
    `MMU_LSU_CAP_ACCFLT(1)
    return tr;
  endfunction

endclass : mmu_lsu_monitor

`undef MMU_LSU_CAP_RESP
`undef MMU_LSU_CAP_ACCFLT

`endif // MMU_LSU_MONITOR_SV
