// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_ptcfg_gen_test.sv
//
// DUT-free harness for mmu_pt_config_gen_base: randomize, emit JSON, and
// confirm riemap accepts it and produces page tables. No RTL is involved,
// which is what makes it able to cover modes this DUT cannot run (Sv48/57,
// two-stage). Acceptance is the whole check -- it does not verify translation
// behaviour.
//
// Does not touch mmu_pt_config_gen.sv, the generator the C910 tests use.
//======================================================================
`ifndef MMU_PTCFG_GEN_TEST_SV
`define MMU_PTCFG_GEN_TEST_SV

class mmu_ptcfg_gen_test extends mmu_base_test;
  `uvm_component_utils(mmu_ptcfg_gen_test)

  function new(string name = "mmu_ptcfg_gen_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    mmu_pt_config_gen_base       cfg;
    PageTableSV_pkg::PageTableSV pt;
    string       json;
    int          n;
    int unsigned seed = 1;

    phase.raise_objection(this, "ptcfg gen running");
    void'($value$plusargs("PT_SEED=%d", seed));

    // Factory create, so a DUT that derives its own generator can swap it in
    // with a type override without touching this test.
    cfg = mmu_pt_config_gen_base::type_id::create("cfg");
    cfg.set_seed(seed);
    cfg.apply_plusarg_overrides();
    // +PT_GLOBAL_PAGES: exercise the fixed-global-pages prepend with a minimal
    // g=1 group, so the hook has coverage without the dynamic-satp sequence.
    if ($test$plusargs("PT_GLOBAL_PAGES")) begin
      cfg.enable_fixed_global_pages = 1'b1;
      cfg.fixed_global_pages_json   =
        {"        {\n          \"id\": \"global_page_0\",\n",
         "          \"num_pages\": 1,\n          \"va\": \"0x100000\",\n",
         "          \"pa\": \"0x80000000\",\n",
         "          \"attributes\": {\n            \"size\": \"4kb\",\n",
         "            \"a\": 1,\n            \"d\": 1,\n            \"g\": 1\n          }\n        }"};
    end
    if (!cfg.randomize())
      `uvm_fatal("PTCFG", "config randomize() failed")
    cfg.apply_post_randomize_overrides();
    cfg.print_config();

    json = cfg.to_json();
    begin
      int fd = $fopen("generated_ptcfg.json", "w");
      if (fd) begin $fwrite(fd, "%s", json); $fclose(fd); end
    end

    pt = new();
    n  = pt.generate_page_tables_from_config_str(json, seed, 0, 0, 0);
    if (n < 0)
      `uvm_error("PTCFG", $sformatf("riemap REJECTED config (n=%0d)", n))
    else
      `uvm_info("PTCFG", $sformatf("riemap ACCEPTED: %0d PTEs", n), UVM_LOW)

    phase.drop_objection(this, "ptcfg gen done");
  endtask

endclass : mmu_ptcfg_gen_test

`endif // MMU_PTCFG_GEN_TEST_SV
