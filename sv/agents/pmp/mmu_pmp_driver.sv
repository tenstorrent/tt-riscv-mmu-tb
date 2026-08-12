// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_pmp_driver.sv
//
// Config-manager driver for the PMP agent. Unlike the IFU/LSU drivers there
// is no DUT request/response handshake to pump: the PMP responder
// (mmu_if's always_comb) reads mmu_if.pmp_cfg combinationally, so
// "driving" a PMP config means writing the whole 16-entry table directly
// into the interface (not through a clocking block -- see mmu_if.sv).
//
// mmu_if.pmp_cfg already carries a full-coverage RWX default so
// pre-agent tests never regress against an empty (all-deny) table. This
// driver's own default flow re-applies an equivalent all-permissive config
// once at reset release -- proving the write path end-to-end without any
// test needing to start a sequence -- and then pulls further
// mmu_pmp_seq_item's from the sequencer, applying each one (e.g. a denying
// config) the same way.
//======================================================================
`ifndef MMU_PMP_DRIVER_SV
`define MMU_PMP_DRIVER_SV

class mmu_pmp_driver extends uvm_driver #(mmu_pmp_seq_item);
  `uvm_component_utils(mmu_pmp_driver)

  virtual mmu_if vif;

  // Broadcasts every applied config toward the monitor (-> its own `ap` ->
  // the scoreboard). The monitor is the point of record for what
  // config is in effect; the driver only writes it into the DUT boundary
  // and announces it.
  uvm_analysis_port #(mmu_pmp_config) cfg_ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg_ap = new("cfg_ap", this);
    if (!uvm_config_db#(virtual mmu_if)::get(this, "", "mmu_vif", vif))
      `uvm_fatal(get_type_name(), "mmu_vif not found in config DB")
  endfunction

  task run_phase(uvm_phase phase);
    wait (vif.cpurst_b === 1'b1);
    apply_default();
    forever begin
      seq_item_port.get_next_item(req);
      apply(req.cfg);
      seq_item_port.item_done();
    end
  endtask

  // Agent default flow: an all-permissive config, equivalent to mmu_if's own
  // Task-2 tie-off default, applied once through the real write path so the
  // driver is proven live even when no test starts a sequence on sqr.
  protected function void apply_default();
    mmu_pmp_config cfg = mmu_pmp_config::type_id::create("pmp_default_cfg");
    cfg.set_all_permissive();
    apply(cfg);
  endfunction

  // Write one 16-entry config into mmu_if.pmp_cfg and broadcast it.
  protected function void apply(mmu_pmp_config cfg);
    foreach (cfg.vld[i])
      vif.pmp_cfg[i] = '{cfg.vld[i], cfg.lo[i], cfg.hi[i], cfg.r[i], cfg.w[i], cfg.x[i], cfg.l[i]};
    check_matchers(cfg);
    cfg_ap.write(cfg);
    `uvm_info(get_type_name(),
      $sformatf("applied PMP config %s: entry0={vld=%0b lo=0x%0h hi=0x%0h r=%0b w=%0b x=%0b l=%0b}",
                cfg.get_name(), cfg.vld[0], cfg.lo[0], cfg.hi[0], cfg.r[0], cfg.w[0], cfg.x[0], cfg.l[0]),
      UVM_LOW)
  endfunction

  // Drift-guard: mmu_if::pmp_match (drives the DUT) and mmu_pmp_config::match
  // (used by the scoreboard) are two copies of the same ct_pmp_acc decode.
  // Assert they agree for the config just written -- over each region's bounds
  // and no-match, under both M and non-M priv (the no-match default is
  // priv-dependent). A silent drift would let the DUT be driven differently
  // than the checker predicts.
  protected function void check_matchers(mmu_pmp_config cfg);
    bit [1:0] privs [2] = '{2'b01, 2'b11};
    foreach (privs[p]) begin
      foreach (cfg.vld[i]) begin
        assert_match(cfg, cfg.lo[i][27:0],       privs[p]);  // region low
        assert_match(cfg, (cfg.hi[i] - 29'd1),   privs[p]);  // region top (incl.)
        assert_match(cfg, cfg.hi[i][27:0],       privs[p]);  // first PPN above (excl. bound)
      end
      assert_match(cfg, 28'h0,        privs[p]);
      assert_match(cfg, 28'hFFF_FFFF, privs[p]);
    end
  endfunction

  protected function void assert_match(mmu_pmp_config cfg, bit [27:0] ppn, bit [1:0] priv);
    bit [3:0] dut_side = vif.pmp_match(ppn, priv);   // what the DUT sees
    bit [3:0] mdl_side = cfg.match(ppn, priv);        // what the scoreboard predicts
    if (dut_side !== mdl_side)
      `uvm_fatal(get_type_name(),
        $sformatf("PMP matcher DRIFT ppn=0x%0h priv=%0b: mmu_if=0x%0h vs config=0x%0h (the two ct_pmp_acc copies diverged)",
                  ppn, priv, dut_side, mdl_side))
  endfunction

endclass : mmu_pmp_driver

`endif // MMU_PMP_DRIVER_SV
