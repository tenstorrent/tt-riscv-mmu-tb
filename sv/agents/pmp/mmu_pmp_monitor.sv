// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_pmp_monitor.sv
//
// Passive monitor for the PMP config-manager agent. There is no DUT config
// bus to sample (pmp_cfg is a plain interface array the driver writes
// directly, not a clocked port), so this monitor does not touch mmu_if at
// all. Instead it is the point of record for "what config is currently
// applied": the driver pushes every config it writes on its cfg_ap, this
// monitor receives it via analysis_export, and re-broadcasts it once on
// `ap` for the scoreboard to subscribe to.
//======================================================================
`ifndef MMU_PMP_MONITOR_SV
`define MMU_PMP_MONITOR_SV

class mmu_pmp_monitor extends uvm_monitor;
  `uvm_component_utils(mmu_pmp_monitor)

  // Driver -> monitor: one write per applied config.
  uvm_analysis_imp #(mmu_pmp_config, mmu_pmp_monitor) analysis_export;

  // Monitor -> scoreboard: re-broadcasts every applied config.
  uvm_analysis_port #(mmu_pmp_config) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    analysis_export = new("analysis_export", this);
    ap              = new("ap", this);
  endfunction

  // uvm_analysis_imp callback: the driver just wrote this cfg into
  // mmu_if.pmp_cfg. Forward it on `ap` and log it once.
  virtual function void write(mmu_pmp_config cfg);
    ap.write(cfg);
    `uvm_info(get_type_name(),
      $sformatf("observed applied PMP config %s (entry0 vld=%0b lo=0x%0h hi=0x%0h)",
                cfg.get_name(), cfg.vld[0], cfg.lo[0], cfg.hi[0]),
      UVM_HIGH)
  endfunction

endclass : mmu_pmp_monitor

`endif // MMU_PMP_MONITOR_SV
