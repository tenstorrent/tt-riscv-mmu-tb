// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_pt_config_gen.sv
//
// Randomizable page-table CONFIG generator for the T-Head C910 MMU.
// Emits the riemap input JSON. Scoped to WHAT THE C910 SUPPORTS:
//   - Sv39, single-stage (satp) only
//   - page sizes 4KB / 2MB / 1GB (weighted)   [Sv39 levels 0/1/2]
//   - permission-weighted pages (RWX / RX / RW / R)
//   - page-fault injection, 0-2 distinct C910-valid causes, weighted, with
//     PER-LEVEL randomization so faults hit non-leaf levels too:
//       EXECUTE (x=0), USER (u=1), ACCESSED (a=0), VALID (v=0), RESERVED (w=1,r=0)
//     NO N(Svnapot)/PBMT: those PTE bit positions are reused as MAEE on C910.
//
// riemap / riemap page-table generation are open source, so a user can
// extend this config (more page groups, attributes, sizes) to whatever their
// target RTL supports — this file intentionally only models the C910 subset.
//======================================================================

`ifndef MMU_PT_CONFIG_GEN_SV
`define MMU_PT_CONFIG_GEN_SV

class mmu_pt_config_gen extends uvm_object;
  `uvm_object_utils(mmu_pt_config_gen)

  typedef enum { P4KB, P2MB, P1GB } page_size_e;   // Sv39 leaf levels 0/1/2

  // C910-valid page-fault causes (no N/PBMT). One shared config serves IFU and
  // LSU: fetch checks X; load checks R; store checks W/D. Walk-structural
  // faults (V, write-only, misalign, leaf-not-found) apply to all access types.
  typedef enum {
    FLT_EXECUTE,   // x=0  -> not executable        (fetch: inst page fault)
    FLT_USER,      // u=1  -> user page in S-mode    (any access)
    FLT_ACCESSED,  // a=0                            (any access)
    FLT_VALID,     // v=0  -> invalid (any level)    (any access)
    FLT_RESERVED,  // r=0,w=1 -> reserved encoding   (any access, any level)
    FLT_READ,      // r=0  -> not readable           (load: page fault)  [LSU]
    FLT_WRITE,     // w=0  -> not writable           (store: page fault) [LSU]
    FLT_DIRTY,     // d=0  -> dirty on store         (store: page fault) [LSU]
    FLT_GLOBAL     // g=1  -> global leaf (NOT a fault; survives INV_ASID).
                   //         Selectable coverage attr, leaf-only.
  } fault_type_e;
  localparam int unsigned NUM_FAULT_TYPES = FLT_GLOBAL + 1;
  localparam int unsigned SV39_MAX_LEVEL  = 2;

  // Fixed C910 memory bounds.
  localparam string PAGING_MODE = "sv39";
  localparam string MMAP_LO = "0x80000000";
  localparam string MMAP_HI = "0x10000000000";      // 2^40 (C910 PA)
  localparam string PA_AND  = "0x000000FFFFFFF000";  // PA[39:12], 4KB aligned

  int unsigned fault_pages = 20;   // pages per fault type

  //--------------------------------------------------------------------
  // Randomized fields
  //--------------------------------------------------------------------
  rand int unsigned num_pages;
  rand bit          use_2mb;
  rand bit          use_1gb;

  // satp ASID (TLB tagging). C910 supports a 16-bit ASID field.
  rand bit [15:0]   asid;

  // Fault selection.
  rand int unsigned num_faults;
  rand bit          flt_sel[NUM_FAULT_TYPES];

  // Forced overrides (from plusargs).
  bit          force_no_fault = 1'b0;
  bit          force_faults   = 1'b0;
  bit          use_forced_faults = 1'b0;
  bit          forced_sel[NUM_FAULT_TYPES];

  // Fixed global pages: when set, the caller
  // supplies a pre-built JSON group of g=1 pages that is PREPENDED to the pages
  // array. Used by the dynamic-satp sequence so the SAME global set persists
  // across every context switch (global = maps in all address spaces).
  bit          enable_fixed_global_pages = 1'b0;
  string       fixed_global_pages_json   = "";

  //--------------------------------------------------------------------
  // Constraints
  //--------------------------------------------------------------------
  constraint c_num_pages { num_pages inside {[400:600]}; }

  constraint c_sizes {
    use_2mb dist { 1 := 80, 0 := 20 };
    use_1gb dist { 1 := 30, 0 := 70 };
  }

  // ASID 0x100..0xFFF (avoids the reset/global 0).
  constraint c_asid { asid inside {[16'h100:16'hFFF]}; }


  // 0-2 distinct faults; NO-FAULT is a weighted outcome.
  // Written with implication operators (not if/else-if) so Verilator's
  // constrained-random codegen handles the conditional dist correctly.
  constraint c_num_faults {
    use_forced_faults -> num_faults == count_forced();
    (!use_forced_faults && force_no_fault) -> num_faults == 0;
    (!use_forced_faults && !force_no_fault && force_faults) ->
        num_faults dist { 1 := 55, 2 := 45 };
    (!use_forced_faults && !force_no_fault && !force_faults) ->
        num_faults dist { 0 := 20, 1 := 45, 2 := 35 };
  }
  constraint c_flt_sel {
    flt_sel.sum() with (int'(item)) == num_faults;
    if (use_forced_faults) foreach (flt_sel[i]) flt_sel[i] == forced_sel[i];
    // GLOBAL is NOT a fault and never enters the random fault mix; G is gated
    // behind explicit fault selection. Random runs keep g=0 everywhere.
    if (!use_forced_faults) flt_sel[FLT_GLOBAL] == 1'b0;
  }

  function new(string name = "mmu_pt_config_gen");
    super.new(name);
  endfunction

  //--------------------------------------------------------------------
  // Forced-fault selection (+PT_FAULTS=NOEXEC,USER,...)
  //--------------------------------------------------------------------
  function int name_to_idx(string s);
    case (s.toupper())
      "NOEXEC","EXECUTE","X":              return FLT_EXECUTE;
      "USER","U":                          return FLT_USER;
      "NOACC","ACCESSED","A":              return FLT_ACCESSED;
      "INVALID","VALID","V":               return FLT_VALID;
      "RESERVED","RESVD","WRITE_NO_READ":  return FLT_RESERVED;
      "READ","NOREAD","R":                 return FLT_READ;
      "WRITE","NOWRITE","W":               return FLT_WRITE;
      "DIRTY","NODIRTY","D":               return FLT_DIRTY;
      "GLOBAL","G":                        return FLT_GLOBAL;
      default: begin
        `uvm_warning("PT_CONFIG_GEN",
          $sformatf("unknown/unsupported fault '%s' (ignored; N/PBMT not on C910)", s))
        return -1;
      end
    endcase
  endfunction

  function void set_forced_faults(string csv);
    int idx, start = 0; string tok;
    foreach (forced_sel[i]) forced_sel[i] = 1'b0;
    for (int c = 0; c <= csv.len(); c++) begin
      byte ch = (c < csv.len()) ? csv.getc(c) : ",";
      if (ch == "," || ch == " ") begin
        if (c > start) begin tok = csv.substr(start, c-1); idx = name_to_idx(tok);
          if (idx >= 0) forced_sel[idx] = 1'b1; end
        start = c + 1;
      end
    end
    use_forced_faults = 1'b1;
  endfunction

  protected function int count_forced();
    int n = 0; foreach (forced_sel[i]) if (forced_sel[i]) n++; return n;
  endfunction

  //--------------------------------------------------------------------
  // JSON emission
  //--------------------------------------------------------------------
  protected function string size_list();
    string s = "\"4kb\"";
    if (use_2mb) s = {s, ", \"2mb\""};
    if (use_1gb) s = {s, ", \"1gb\""};
    return s;
  endfunction

  protected function bit is_fault_sel(fault_type_e f); return flt_sel[f]; endfunction

  // Per-level weighted list:
  //   levels >= 3 (root, deeper modes): bad value weight 1  (99/1)
  //   levels 0/1/2 (Sv39):              bad value weight 2  (98/2)
  // Sv39 only has levels 0-2, so in practice every level uses 98/2; the
  // level>=3 branch keeps the helper correct if a deeper mode is ever added.
  protected function string lvl_weight(int level, int good, int bad);
    int bw = (level >= 3) ? 1 : 2;
    return $sformatf("[{\"value\": %0d, \"weight\": %0d}, {\"value\": %0d, \"weight\": %0d}]",
                     good, 100 - bw, bad, bw);
  endfunction

  // Per-level keys for a faulted bit at all Sv39 levels.
  protected function string level_keys(string b, int good, int bad);
    string s = "";
    for (int lvl = 0; lvl <= SV39_MAX_LEVEL; lvl++)
      s = {s, $sformatf(",\n            \"%s_level%0d\": %s", b, lvl, lvl_weight(lvl, good, bad))};
    return s;
  endfunction

  // Plain (leaf) weighted attribute: riemap applies it to the LEAF PTE only,
  // whatever level the leaf is for that page. Same 98/2 split as lvl_weight().
  protected function string leaf_weight(int good, int bad);
    return $sformatf("[{\"value\": %0d, \"weight\": 98}, {\"value\": %0d, \"weight\": 2}]", good, bad);
  endfunction

  // Fault attributes block: emit ONLY the keys for the SELECTED
  // faults. Non-selected PTE bits are left OUT entirely -- riescue/riemap
  // supplies the defaults (a valid executable leaf: v=1,r=1,x=1,a=1,d=1,u=0).
  // No fault selected -> empty (riemap defaults produce clean pages).
  //   VALID (v=0)     -> PER LEVEL (v_level0/1/2): invalid PTE faults at ANY
  //                      walk level (step 3) -> non-leaf coverage.
  //   RESERVED (r=0,w=1) write-only -> r_level AND w_level on ALL levels, so the
  //                      R=0,W=1 encoding occurs at leaf AND non-leaf (step 3).
  //   USER/ACCESSED/EXECUTE -> leaf-only (plain weighted attr): C910 checks
  //                      permission/A/D/U only at the leaf (ptw_leaf_vld, 1.10
  //                      steps 5/7).
  // No-fault clean leaf attributes.
  protected function string simple_attrs();
    return "\"r\": 1, \"w\": 1, \"x\": 1, \"a\": 1, \"d\": 1, \"u\": 0";
  endfunction

  // Fault attributes: emit ONLY per-level keys for the SELECTED faults;
  // non-selected bits are left to riescue defaults. Weights:
  //   V (VALID)                  -> value 1 dominant (98/2)
  //   R/W/X/A/D/U                -> value 0 dominant (98/2)
  // value-0-dominant is POINTER-SAFE: non-leaf PTEs get R=X=0 (stay pointers),
  // and the fault lands at the leaf. r_level/w_level are
  // SHARED (READ|RESERVED and WRITE|RESERVED) so no duplicate keys; the R=0&W=1
  // coincidence yields the reserved write-only encoding at any level.
  protected function string gen_attrs();
    string a = "";
    // Per-level (pointer-safe, value-0-dominant) for the walk/permission bits:
    if (is_fault_sel(FLT_READ)  || is_fault_sel(FLT_RESERVED)) a = {a, level_keys("r", 0, 1)};
    if (is_fault_sel(FLT_WRITE) || is_fault_sel(FLT_RESERVED)) a = {a, level_keys("w", 0, 1)};
    if (is_fault_sel(FLT_EXECUTE))  a = {a, level_keys("x", 0, 1)};
    if (is_fault_sel(FLT_VALID))    a = {a, level_keys("v", 1, 0)};  // v=1 dom, v=0 at 2%
    // A / U / D are LEAF-ONLY (C910 checks them only at the leaf; on a non-leaf
    // PTE they are reserved and must not be set -- per-level would trip the
    // Whisper non-leaf-A/D/U fault). Plain leaf weighted attrs; the leaf keeps a
    // valid A/D otherwise, and riemap applies them at whatever level is the
    // leaf for each page.  (DIRTY is a store-only fault -> LSU, not IFU.)
    if (is_fault_sel(FLT_ACCESSED)) a = {a, ",\n            \"a\": ", leaf_weight(1,0)};
    if (is_fault_sel(FLT_DIRTY))    a = {a, ",\n            \"d\": ", leaf_weight(1,0)};
    if (is_fault_sel(FLT_USER))     a = {a, ",\n            \"u\": ", leaf_weight(0,1)};
    // GLOBAL: leaf-only, value-0-dominant: g=0
    // at 98%, g=1 at 2%. Only emitted when GLOBAL is explicitly selected.
    if (is_fault_sel(FLT_GLOBAL))   a = {a, ",\n            \"g\": ", leaf_weight(0,1)};
    // Strip the leading ",\n            " (14 chars) so the block slots cleanly
    // after "size".
    if (a.len() > 14) return a.substr(14, a.len()-1);
    return "";
  endfunction

  virtual function string to_json();
    string attrs = gen_attrs();
    string body;
    string pages;
    // No fault -> clean executable leaf (RWX, so every fetch translates
    // successfully). Fault -> only the selected fault keys; non-selected bits
    // use riescue defaults.
    body = (attrs == "") ? simple_attrs() : attrs;
    pages = $sformatf({"        {\n          \"id\": \"single_stage_pages\",\n",
      "          \"num_pages\": %0d,\n          \"pa_and\": \"%s\",\n",
      "          \"attributes\": {\n            \"size\": [%s],\n            %s\n          }\n        }"},
      num_pages, PA_AND, size_list(), body);
    // Prepend the fixed global-page group (kept first) so the same g=1
    // pages exist in every context. Each element is a complete page object.
    if (enable_fixed_global_pages && fixed_global_pages_json.len() > 0)
      pages = {fixed_global_pages_json, ",\n", pages};
    return $sformatf({"{\n",
      "  \"mmap\": [[\"%s\", \"%s\"]],\n  \"spaces\": {\n    \"space1\": {\n",
      "      \"twostage\": false,\n      \"paging_mode\": \"%s\",\n      \"pages\": [\n%s\n      ]\n",
      "    }\n  }\n}\n"},
      MMAP_LO, MMAP_HI, PAGING_MODE, pages);
  endfunction

  //--------------------------------------------------------------------
  // Summary print
  //--------------------------------------------------------------------
  function string faults_str();
    string names[NUM_FAULT_TYPES] = '{"EXECUTE","USER","ACCESSED","VALID","RESERVED","READ","WRITE","DIRTY","GLOBAL"};
    string s = "";
    foreach (flt_sel[i]) if (flt_sel[i]) s = (s=="") ? names[i] : {s, ",", names[i]};
    return (s == "") ? "NONE" : s;
  endfunction

  virtual function void print_summary();
    `uvm_info("PT_CONFIG_GEN", "--- PT config randomization (C910: Sv39, single-stage) ---", UVM_LOW)
    `uvm_info("PT_CONFIG_GEN", $sformatf("  num_pages       : %0d", num_pages), UVM_LOW)
    `uvm_info("PT_CONFIG_GEN", $sformatf("  page_sizes      : 4kb%s%s",
              use_2mb ? ",2mb" : "", use_1gb ? ",1gb" : ""), UVM_LOW)
    `uvm_info("PT_CONFIG_GEN", $sformatf("  asid            : 0x%04h", asid), UVM_LOW)
    `uvm_info("PT_CONFIG_GEN", $sformatf("  num_faults      : %0d", num_faults), UVM_LOW)
    `uvm_info("PT_CONFIG_GEN", $sformatf("  selected_faults : %s%s", faults_str(),
              use_forced_faults ? " (forced)" : ""), UVM_LOW)
  endfunction

endclass : mmu_pt_config_gen

`endif // MMU_PT_CONFIG_GEN_SV
