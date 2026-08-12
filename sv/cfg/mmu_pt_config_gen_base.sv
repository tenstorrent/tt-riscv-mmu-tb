// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_pt_config_gen_base.sv
//
// DUT-agnostic page-table config generator: randomizes a config and emits the
// riemap input JSON. Carries the full feature set, so a DUT that only wants
// a subset can extend it and AND in narrowing constraints.
//
// It is NOT the generator this testbench uses. mmu_pt_config_gen.sv drives
// every C910 test here and is deliberately independent -- see the note in
// mmu_env_pkg.sv. This class exists for reuse on other DUTs and as the thing
// mmu_ptcfg_gen_test exercises.
//
// Covers Sv39/48/57, all six page sizes with weighted selection, the VS and
// G-stage fault taxonomy, and single / two-stage / mixed translation. The PA
// window is sized from the paging mode by set_bounds_for_mode().
//
// Not modelled: the reference's large-G-stage page group and its
// SAFE_ISOLATED split workaround. Both are tuning for a specific fault
// campaign rather than schema requirements.
//
// Self-contained by design: no DUT packages, and the only output is a JSON
// string, so the class is reusable across testbenches.
//
// Correctness here means only "riemap accepted the config and produced page
// tables". Nothing in this repo drives its output into RTL, so the two-stage
// and Sv48/57 paths in particular have never been checked against a DUT.
//======================================================================
`ifndef MMU_PT_CONFIG_GEN_BASE_SV
`define MMU_PT_CONFIG_GEN_BASE_SV

class mmu_pt_config_gen_base extends uvm_object;
  `uvm_object_utils(mmu_pt_config_gen_base)

  typedef enum {
    MMUTB_PAGING_SV39,
    MMUTB_PAGING_SV48,
    MMUTB_PAGING_SV57,
    MMUTB_PAGING_DISABLE          // No translation. Emitted as "disable";
                                  // riemap currently aborts on it (map_hyp
                                  // lookup), so only reachable via +PT_MODE.
  } mmutb_paging_mode_e;

  // Page sizes are the use_* bits below, not an enum: riemap takes a set,
  // and one bit per size lets constraints weight each independently.

  // Which PTE bits get perturbed. VS entries apply to single-stage; the G_
  // entries are two-stage only and are excluded from selection until then.
  typedef enum {
    PT_FLT_NONE,

    PT_FLT_VALID,              // v=0
    PT_FLT_READ,               // r=0
    PT_FLT_WRITE,              // w=0
    PT_FLT_EXECUTE,            // x=0
    PT_FLT_USER,               // u mismatch
    PT_FLT_ACCESSED,           // a=0
    PT_FLT_DIRTY,              // d=0
    PT_FLT_RESERVED,           // reserved bits set
    PT_FLT_RSW,                // rsw bits (software use, not a fault)
    PT_FLT_WRITE_NO_READ,      // w=1,r=0 -- illegal encoding
    PT_FLT_GLOBAL,             // g bit (not a fault)
    PT_FLT_NAPOT,              // n bit
    PT_FLT_PBMT,               // pbmt non-zero

    PT_FLT_G_VALID,
    PT_FLT_G_READ,
    PT_FLT_G_WRITE,
    PT_FLT_G_EXECUTE,
    PT_FLT_G_USER,
    PT_FLT_G_ACCESSED,
    PT_FLT_G_DIRTY,
    PT_FLT_G_RESERVED,
    PT_FLT_G_RSW,
    PT_FLT_G_GLOBAL,
    PT_FLT_G_NAPOT,
    PT_FLT_G_PBMT
  } pt_fault_type_e;

  // Memory bounds, sized from the paging mode by set_bounds_for_mode() after
  // randomize(). A DUT subclass overrides that to pin its own PA window.
  string mmap_lo = "0x80000000";
  string mmap_hi = "0x10000000000";
  string pa_and  = "0x000000FFFFFFF000";   // PA[39:12], 4KB aligned

  //--------------------------------------------------------------------
  // Randomized configuration
  //--------------------------------------------------------------------
  rand mmutb_paging_mode_e paging_mode;
  rand int unsigned        num_pages;
  rand bit [15:0]          asid;

  // One enable per page size, in the canonical order used by size_name().
  rand bit use_4kb, use_64kb, use_2mb, use_1gb, use_512gb, use_256tb;

  rand pt_fault_type_e selected_faults[];
  rand int unsigned    num_faults;

  // Two-stage (H-extension) translation.
  //   twostage=0, mixed=0 -> one single-stage space
  //   twostage=1, mixed=0 -> one VS+G space
  //   mixed=1             -> space1 single-stage + space2 VS+G
  rand bit                 twostage;
  rand bit                 mixed_mode;
  rand mmutb_paging_mode_e gstage_paging_mode;
  rand int unsigned        twostage_num_pages;
  // G-stage page size used to translate the VS leaf / non-leaf PTE, as an index
  // into size_name(). riemap takes one size per field, not a set.
  rand int                 g_leaf_idx;
  rand int                 g_nonleaf_idx;

  //--------------------------------------------------------------------
  // Knobs (not randomized; set by plusargs or a subclass before randomize)
  //--------------------------------------------------------------------
  bit       disable_256tb = 1'b0;   // +PT_NO_256TB
  bit       size_forced   = 1'b0;   // +PT_SIZE pinned the set
  bit [5:0] forced_size;            // one bit per size, canonical order
  bit       pages_forced  = 1'b0;   // +PT_NUM_PAGES pinned num_pages
  bit       faults_forced = 1'b0;   // +PT_NUM_FAULTS pinned num_faults
  bit       disable_global_faults = 1'b0;

  // +PT_FAULT_TYPE: exact fault set, applied after randomize().
  pt_fault_type_e forced_fault_types[$];
  bit             use_forced_faults = 1'b0;

  // 1 => emit [{"value","weight"}, ...]; 0 => emit the plain ["4kb", ...] form
  // (uniform pick in riemap). A DUT subclass picks the form it needs.
  bit emit_weighted_sizes = 1'b1;

  // Caller-supplied JSON group of g=1 pages, PREPENDED to the pages array.
  // A global page maps in every address space, so the dynamic-satp flow uses
  // this to keep one set alive across context switches.
  bit    enable_fixed_global_pages = 1'b0;
  string fixed_global_pages_json   = "";

  //--------------------------------------------------------------------
  // Constraints -- the general legal space. A subclass narrows this.
  //--------------------------------------------------------------------
  // Skipped when +PT_NUM_PAGES pinned the value, which is deliberately allowed
  // outside this range. c_page_count_vs_size narrows it for huge pages.
  constraint c_num_pages {
    if (!pages_forced && !use_512gb && !use_256tb) {
      if (mixed_mode) num_pages inside {[150:300]};
      else            num_pages inside {[400:600]};
    }
  }

  constraint c_asid { asid inside {[16'h100:16'hFFF]}; }

  constraint c_page_sizes {
    // Never an empty size list, however the bits were forced.
    use_4kb || use_64kb || use_2mb || use_1gb || use_512gb || use_256tb;
    // Free choice: 4kb always on, larger sizes weighted opt-ins.
    if (!size_forced) {
      use_4kb == 1'b1;
      use_2mb   dist { 1 := 80, 0 := 20 };
      use_1gb   dist { 1 := 30, 0 := 70 };
      use_64kb  dist { 1 := 20, 0 := 80 };
      use_512gb dist { 1 := 10, 0 := 90 };
      use_256tb dist { 1 :=  5, 0 := 95 };
    }
  }

  // Soft, so a size illegal for the mode drops out rather than failing
  // randomize -- the same filtering riemap does on its own input.
  constraint c_size_forced {
    if (size_forced) {
      soft use_4kb   == forced_size[0];
      soft use_64kb  == forced_size[1];
      soft use_2mb   == forced_size[2];
      soft use_1gb   == forced_size[3];
      soft use_512gb == forced_size[4];
      soft use_256tb == forced_size[5];
    }
  }

  constraint c_no_256tb { (disable_256tb) -> use_256tb == 1'b0; }

  // A page size only makes sense if the mode has a level for it.
  constraint c_sizes_vs_mode {
    (paging_mode == MMUTB_PAGING_SV39)    -> (use_512gb == 0 && use_256tb == 0);
    (paging_mode == MMUTB_PAGING_SV48)    -> (use_256tb == 0);
    (paging_mode == MMUTB_PAGING_DISABLE) -> (use_64kb == 0 && use_2mb == 0 &&
                                              use_1gb  == 0 && use_512gb == 0 && use_256tb == 0);
  }

  //--------------------------------------------------------------------
  // Fault selection
  //--------------------------------------------------------------------
  // Huge pages get fewer of them, or they exhaust the PA window. Weighted size
  // arrays already make them rare; this bounds the worst case.
  constraint c_page_count_vs_size {
    if (!pages_forced) {
      if      (use_256tb) num_pages inside {[ 75:120]};
      else if (use_512gb) num_pages inside {[100:150]};
    }
  }

  // The bound is not cosmetic: selected_faults.size() tracks num_faults, so an
  // unbounded value makes the solver try to size an array from a random int.
  constraint c_num_faults {
    num_faults <= 8;
    if (!faults_forced) num_faults dist { 0 := 5, 1 := 25, 2 := 35, 3 := 35 };
  }

  constraint c_selected_faults {
    selected_faults.size() == num_faults;
    unique { selected_faults };
    // An explicit +PT_NUM_FAULTS=N means N faults: keep NONE out, or it would
    // be drawn into the set and wipe it in post_randomize.
    if (faults_forced && num_faults > 0)
      foreach (selected_faults[i]) selected_faults[i] != PT_FLT_NONE;
    foreach (selected_faults[i])
      (disable_global_faults) -> (selected_faults[i] != PT_FLT_GLOBAL &&
                                  selected_faults[i] != PT_FLT_G_GLOBAL);
  }

  // G faults need a G-stage to act on.
  constraint c_fault_g_needs_gstage {
    if (gstage_paging_mode == MMUTB_PAGING_DISABLE)
      foreach (selected_faults[i])
        !(selected_faults[i] inside {PT_FLT_G_VALID, PT_FLT_G_READ, PT_FLT_G_WRITE,
                                     PT_FLT_G_EXECUTE, PT_FLT_G_USER, PT_FLT_G_ACCESSED,
                                     PT_FLT_G_DIRTY, PT_FLT_G_RESERVED, PT_FLT_G_RSW,
                                     PT_FLT_G_GLOBAL, PT_FLT_G_NAPOT, PT_FLT_G_PBMT});
  }

  // Two-stage: VS and G faults both in play.
  constraint c_fault_two_stage {
    if (gstage_paging_mode != MMUTB_PAGING_DISABLE)
      foreach (selected_faults[i])
        selected_faults[i] dist {
          PT_FLT_VALID       := 10, PT_FLT_READ        := 10,
          PT_FLT_WRITE       := 10, PT_FLT_EXECUTE     := 10,
          PT_FLT_USER        :=  8, PT_FLT_ACCESSED    := 20,
          PT_FLT_DIRTY       := 20, PT_FLT_RESERVED    :=  4,
          PT_FLT_RSW         :=  2, PT_FLT_NONE        :=  8,
          PT_FLT_G_VALID     := 10, PT_FLT_G_READ      := 10,
          PT_FLT_G_WRITE     := 10, PT_FLT_G_EXECUTE   := 10,
          PT_FLT_G_USER      :=  8, PT_FLT_G_ACCESSED  := 15,
          PT_FLT_G_DIRTY     := 15, PT_FLT_G_RESERVED  :=  4,
          PT_FLT_G_RSW       :=  2, PT_FLT_G_GLOBAL    :=  4
        };
  }

  // Single-stage: VS faults only.
  constraint c_fault_single_stage {
    if (gstage_paging_mode == MMUTB_PAGING_DISABLE)
    foreach (selected_faults[i])
      selected_faults[i] dist {
        PT_FLT_VALID         := 15,
        PT_FLT_READ          := 15,
        PT_FLT_WRITE         := 15,
        PT_FLT_EXECUTE       := 15,
        PT_FLT_USER          := 10,
        PT_FLT_ACCESSED      := 40,
        PT_FLT_DIRTY         := 40,
        PT_FLT_RESERVED      :=  5,
        PT_FLT_RSW           :=  3,
        PT_FLT_WRITE_NO_READ :=  5,
        PT_FLT_GLOBAL        :=  5,
        PT_FLT_NONE          := 10,
        PT_FLT_NAPOT         := 10,
        PT_FLT_PBMT          := 35
      };
  }

  //--------------------------------------------------------------------
  // Translation mode
  //--------------------------------------------------------------------
  constraint c_translation_mode {
    // Single-stage dominates; a DUT subclass without H pins twostage/mixed to 0.
    twostage   dist { 0 := 65, 1 := 35 };
    mixed_mode dist { 0 := 85, 1 := 15 };
    (mixed_mode == 1) -> (twostage == 1);   // mixed needs a two-stage space2
  }

  constraint c_gstage_mode {
    // G-stage only exists under two-stage. DISABLE there means VS-only.
    (twostage == 0) -> (gstage_paging_mode == MMUTB_PAGING_DISABLE);
    (twostage == 1) -> (gstage_paging_mode inside {MMUTB_PAGING_SV39,
                                                   MMUTB_PAGING_SV48,
                                                   MMUTB_PAGING_SV57});
    // The G-stage has to be able to reach every GPA the VS stage hands out, so
    // it can never be the narrower mode. Enum order is sv39 < sv48 < sv57.
    (twostage == 1) -> (gstage_paging_mode >= paging_mode);
  }

  constraint c_twostage_pages {
    // Huge VS pages cost far more under a G-stage (each needs its own G-stage
    // tables), so they cap harder here than in the single-stage case.
    if (use_256tb)      twostage_num_pages inside {[ 40: 60]};
    else if (use_512gb) twostage_num_pages inside {[ 50: 80]};
    // Mixed runs two spaces off one PA window, so both get fewer pages.
    else if (mixed_mode) twostage_num_pages inside {[100:200]};
    else                 twostage_num_pages inside {[200:400]};
    // 4kb / 2mb / 1gb only: the G-stage sizes above these need a PA window
    // wider than the VS mode guarantees.
    g_leaf_idx    inside {0, 2, 3};
    g_nonleaf_idx inside {0, 2, 3};
  }

  // Sv39/48/57 all randomize freely; the PA window follows via
  // set_bounds_for_mode(). DISABLE is soft-excluded because riemap aborts on
  // it -- soft so an explicit +PT_MODE=disable still gets there.
  constraint c_mode_legal { soft paging_mode != MMUTB_PAGING_DISABLE; }

  //--------------------------------------------------------------------
  int unsigned seed = 1;

  function new(string name = "mmu_pt_config_gen_base");
    super.new(name);
  endfunction

  function void set_seed(int unsigned s);
    seed = s;
    this.srandom(s);
  endfunction

  protected function bit str_to_paging_mode(string s, output mmutb_paging_mode_e m);
    case (s.tolower())
      "sv39": m = MMUTB_PAGING_SV39;
      "sv48": m = MMUTB_PAGING_SV48;
      "sv57": m = MMUTB_PAGING_SV57;
      "disable", "bare": m = MMUTB_PAGING_DISABLE;
      default: return 1'b0;
    endcase
    return 1'b1;
  endfunction

  // Command-line overrides. Call BEFORE randomize().
  virtual function void apply_plusarg_overrides();
    int unsigned        s, np, nf;
    string              ms, sz, ft, vr, gm;
    mmutb_paging_mode_e m;
    if ($value$plusargs("PT_SEED=%d", s)) set_seed(s);
    if ($value$plusargs("PT_MODE=%s", ms)) begin
      if (str_to_paging_mode(ms, m)) begin
        paging_mode = m;
        paging_mode.rand_mode(0);      // pin it through randomize()
      end
      else
        `uvm_warning("PT_CFG_BASE", $sformatf("unknown +PT_MODE=%s (ignored)", ms))
    end
    if ($value$plusargs("PT_SIZE=%s", sz))
      if (!parse_page_sizes(sz))
        `uvm_warning("PT_CFG_BASE", $sformatf("no known size in +PT_SIZE=%s (ignored)", sz))
    if ($value$plusargs("PT_NUM_PAGES=%d", np)) begin
      num_pages    = np;
      pages_forced = 1'b1;
      num_pages.rand_mode(0);
    end
    if ($value$plusargs("PT_NUM_FAULTS=%d", nf)) begin
      num_faults    = nf;
      faults_forced = 1'b1;
      num_faults.rand_mode(0);
    end
    if ($value$plusargs("PT_FAULT_TYPE=%s", ft)) parse_fault_types(ft);
    if ($value$plusargs("PT_VARIANT=%s", vr)) begin
      case (vr.tolower())
        "single", "single_stage": begin twostage = 1'b0; mixed_mode = 1'b0; end
        "two_stage", "twostage":  begin twostage = 1'b1; mixed_mode = 1'b0; end
        "mixed":                  begin twostage = 1'b1; mixed_mode = 1'b1; end
        default:
          `uvm_warning("PT_CFG_BASE", $sformatf("unknown +PT_VARIANT=%s (ignored)", vr))
      endcase
      if (vr.tolower() inside {"single", "single_stage", "two_stage", "twostage", "mixed"}) begin
        twostage.rand_mode(0);
        mixed_mode.rand_mode(0);
      end
    end
    if ($value$plusargs("PT_GSTAGE_MODE=%s", gm)) begin
      if (str_to_paging_mode(gm, m)) begin
        gstage_paging_mode = m;
        gstage_paging_mode.rand_mode(0);
      end
      else
        `uvm_warning("PT_CFG_BASE", $sformatf("unknown +PT_GSTAGE_MODE=%s (ignored)", gm))
    end
    if ($test$plusargs("PT_NO_256TB"))    disable_256tb       = 1'b1;
    if ($test$plusargs("PT_PLAIN_SIZES")) emit_weighted_sizes = 1'b0;
  endfunction

  // Accepts the bare name ("VALID"), the VS_ form, and the full enum spelling
  // ("PT_FLT_VALID") so log output can be pasted straight back as a plusarg.
  function pt_fault_type_e str_to_fault_type(string s, output bit ok);
    string u = s.toupper();
    ok = 1'b1;
    if (u.len() > 7 && u.substr(0, 6) == "PT_FLT_") u = u.substr(7, u.len() - 1);
    case (u)
      "NONE":                              return PT_FLT_NONE;
      "VALID",    "VS_VALID":              return PT_FLT_VALID;
      "READ",     "VS_READ":               return PT_FLT_READ;
      "WRITE",    "VS_WRITE":              return PT_FLT_WRITE;
      "EXECUTE",  "VS_EXECUTE":            return PT_FLT_EXECUTE;
      "USER",     "VS_USER":               return PT_FLT_USER;
      "ACCESSED", "VS_ACCESSED":           return PT_FLT_ACCESSED;
      "DIRTY",    "VS_DIRTY":              return PT_FLT_DIRTY;
      "RESERVED", "VS_RESERVED":           return PT_FLT_RESERVED;
      "RSW",      "VS_RSW":                return PT_FLT_RSW;
      "WRITE_NO_READ", "VS_WRITE_NO_READ": return PT_FLT_WRITE_NO_READ;
      "GLOBAL", "VS_GLOBAL", "GLOBAL_BIT": return PT_FLT_GLOBAL;
      "NAPOT",    "VS_NAPOT":              return PT_FLT_NAPOT;
      "PBMT",     "VS_PBMT":               return PT_FLT_PBMT;
      "G_VALID":                           return PT_FLT_G_VALID;
      "G_READ":                            return PT_FLT_G_READ;
      "G_WRITE":                           return PT_FLT_G_WRITE;
      "G_EXECUTE":                         return PT_FLT_G_EXECUTE;
      "G_USER":                            return PT_FLT_G_USER;
      "G_ACCESSED":                        return PT_FLT_G_ACCESSED;
      "G_DIRTY":                           return PT_FLT_G_DIRTY;
      "G_RESERVED":                        return PT_FLT_G_RESERVED;
      "G_RSW":                             return PT_FLT_G_RSW;
      "G_GLOBAL":                          return PT_FLT_G_GLOBAL;
      "G_NAPOT":                           return PT_FLT_G_NAPOT;
      "G_PBMT":                            return PT_FLT_G_PBMT;
      default: begin
        ok = 1'b0;
        return PT_FLT_NONE;
      end
    endcase
  endfunction

  // "VALID,EXECUTE" -> forced set. An explicit NONE means "no faults".
  function void parse_fault_types(string s);
    string          toks[$];
    pt_fault_type_e flt;
    bit             ok;
    tokenize_csv(s, toks);
    forced_fault_types.delete();
    foreach (toks[i]) begin
      flt = str_to_fault_type(toks[i], ok);
      if (!ok)
        `uvm_warning("PT_CFG_BASE", $sformatf("unknown fault type '%s' (ignored)", toks[i]))
      else
        forced_fault_types.push_back(flt);
    end
    use_forced_faults = (forced_fault_types.size() > 0);
  endfunction

  protected function void apply_forced_faults();
    if (!use_forced_faults || forced_fault_types.size() == 0) return;
    selected_faults = new[forced_fault_types.size()];
    foreach (forced_fault_types[i]) selected_faults[i] = forced_fault_types[i];
    num_faults = selected_faults.size();
  endfunction

  // PT_FLT_NONE anywhere in the set means no fault injection at all.
  protected function void enforce_none_means_no_fault();
    foreach (selected_faults[i])
      if (selected_faults[i] == PT_FLT_NONE) begin
        selected_faults = new[0];
        num_faults      = 0;
        return;
      end
  endfunction

  // PA window per mode. Sv48/57 need room for 512gb/256tb pages: a 256tb page
  // must land on a 256tb boundary, so the window has to span several of them.
  // A DUT subclass overrides this to pin its own bounds.
  virtual function void set_bounds_for_mode();
    case (paging_mode)
      MMUTB_PAGING_SV48: begin
        mmap_hi = "0x1000000000000";          // 2^48
        pa_and  = "0x0000FFFFFFFFF000";
      end
      MMUTB_PAGING_SV57: begin
        mmap_hi = "0x8000000000000";          // 2^51 -- ~8 256tb slots
        pa_and  = "0x0007FFFFFFFFF000";
      end
      default: begin
        mmap_hi = "0x10000000000";            // 2^40
        pa_and  = "0x000000FFFFFFF000";
      end
    endcase
    // A G-stage adds a second full set of page tables per mapping, so Sv39
    // two-stage needs more room than its 2^40 single-stage window.
    if (twostage && paging_mode == MMUTB_PAGING_SV39) begin
      mmap_hi = "0x1000000000000";
      pa_and  = "0x0000FFFFFFFFF000";
    end
  endfunction

  // Fix-ups that need the randomized values. Call AFTER randomize().
  virtual function void apply_post_randomize_overrides();
    apply_forced_faults();
    enforce_none_means_no_fault();
    set_bounds_for_mode();
  endfunction

  //--------------------------------------------------------------------
  // JSON emission
  //--------------------------------------------------------------------
  function string get_paging_mode_str();
    case (paging_mode)
      MMUTB_PAGING_SV48:    return "sv48";
      MMUTB_PAGING_SV57:    return "sv57";
      MMUTB_PAGING_DISABLE: return "disable";   // riemap spelling, not "bare"
      default:              return "sv39";
    endcase
  endfunction

  // Canonical size order. Index 0..2 are the "small" sizes that share whatever
  // weight the large ones leave behind.
  localparam int NUM_SIZES  = 6;
  localparam int FIRST_LARGE = 3;

  protected function string size_name(int i);
    case (i)
      0: return "4kb";
      1: return "64kb";
      2: return "2mb";
      3: return "1gb";
      4: return "512gb";
      default: return "256tb";
    endcase
  endfunction

  protected function bit size_en(int i);
    case (i)
      0: return use_4kb;
      1: return use_64kb;
      2: return use_2mb;
      3: return use_1gb;
      4: return use_512gb;
      default: return use_256tb;
    endcase
  endfunction

  // Fixed shares for the large sizes; small sizes split the remainder. Keeps
  // huge pages rare so they don't exhaust the PA window.
  protected function int large_weight(int i);
    case (i)
      3: return 20;   // 1gb
      4: return  3;   // 512gb
      default: return 1;   // 256tb
    endcase
  endfunction

  protected function string plain_size_list();
    string s = "";
    for (int i = 0; i < NUM_SIZES; i++)
      if (size_en(i)) s = {s, (s == "") ? "" : ", ", $sformatf("\"%s\"", size_name(i))};
    return s;
  endfunction

  protected function string weighted_size_list();
    int    w[NUM_SIZES];
    int    remaining = 100;
    int    n_small = 0;
    int    per, extra;
    string s = "";

    for (int i = 0; i < NUM_SIZES; i++) begin
      w[i] = 0;
      if (!size_en(i)) continue;
      if (i >= FIRST_LARGE) begin
        w[i] = large_weight(i);
        remaining -= w[i];
      end
      else n_small++;
    end

    if (n_small > 0) begin
      per   = remaining / n_small;
      extra = remaining % n_small;
      for (int i = 0; i < FIRST_LARGE; i++)
        if (size_en(i)) begin
          w[i] = per;
          if (extra > 0) begin w[i]++; extra--; end
        end
    end
    else if (remaining > 0) begin
      // Large sizes only: hand the surplus to the smallest one enabled.
      for (int i = FIRST_LARGE; i < NUM_SIZES; i++)
        if (size_en(i)) begin w[i] += remaining; break; end
    end

    for (int i = 0; i < NUM_SIZES; i++)
      if (size_en(i))
        s = {s, (s == "") ? "" : ", ",
             $sformatf("{\"value\": \"%s\", \"weight\": %0d}", size_name(i), w[i])};
    return s;
  endfunction

  protected function string size_list();
    return emit_weighted_sizes ? weighted_size_list() : plain_size_list();
  endfunction

  protected function string gmode_str();
    case (gstage_paging_mode)
      MMUTB_PAGING_SV48: return "sv48";
      MMUTB_PAGING_SV57: return "sv57";
      default:           return "sv39";
    endcase
  endfunction

  // Split on commas/spaces, dropping empties.
  protected function void tokenize_csv(string s, ref string toks[$]);
    string tok = "";
    byte   c;
    toks.delete();
    for (int p = 0; p <= s.len(); p++) begin
      c = (p == s.len()) ? "," : s[p];
      if (c == "," || c == " ") begin
        if (tok.len() > 0) toks.push_back(tok);
        tok = "";
      end
      else tok = {tok, string'(c)};
    end
  endfunction

  // "4kb,2mb,1gb" -> pin exactly that set. Returns 0 if nothing matched.
  function bit parse_page_sizes(string s);
    string    toks[$];
    bit [5:0] sel = 6'b0;
    tokenize_csv(s, toks);
    foreach (toks[t])
      for (int i = 0; i < NUM_SIZES; i++)
        if (toks[t].tolower() == size_name(i)) sel[i] = 1'b1;
    if (sel == 6'b0) return 1'b0;
    forced_size = sel;
    size_forced = 1'b1;
    return 1'b1;
  endfunction

  // A clean, fully-permissioned leaf.
  protected virtual function string simple_attrs();
    return "\"r\": 1, \"w\": 1, \"x\": 1, \"a\": 1, \"d\": 1, \"u\": 0";
  endfunction

  //--------------------------------------------------------------------
  // Fault attributes
  //
  // Only SELECTED faults emit keys. Weights are per level and deliberately
  // lopsided: high levels stay valid so the walk reaches a leaf, and the fault
  // chance rises toward the leaf where it is actually interesting.
  //--------------------------------------------------------------------
  function int get_max_level(mmutb_paging_mode_e mode);
    case (mode)
      MMUTB_PAGING_SV48: return 3;
      MMUTB_PAGING_SV57: return 4;
      default:           return 2;   // sv39 / disable
    endcase
  endfunction

  function bit is_fault_selected(pt_fault_type_e flt);
    foreach (selected_faults[i]) if (selected_faults[i] == flt) return 1'b1;
    return 1'b0;
  endfunction

  protected function string weighted_attr(int value, int weight);
    return $sformatf("{\"value\": %0d, \"weight\": %0d}", value, weight);
  endfunction

  // v=1 dominates; slightly looser near the leaf.
  protected function string w_valid(int level);
    return (level >= 3) ? "[{\"value\": 1, \"weight\": 99}, {\"value\": 0, \"weight\": 1}]"
                        : "[{\"value\": 1, \"weight\": 98}, {\"value\": 0, \"weight\": 2}]";
  endfunction

  // a/d/r/w/x/u/g: 0 dominates (0 is also the correct non-leaf encoding).
  protected function string w_adrwx(int level);
    return (level >= 3) ? "[{\"value\": 0, \"weight\": 99}, {\"value\": 1, \"weight\": 1}]"
                        : "[{\"value\": 0, \"weight\": 98}, {\"value\": 1, \"weight\": 2}]";
  endfunction

  protected function string w_rsw_reserved(int level);
    return (level >= 3) ? "[{\"value\": 0, \"weight\": 99}, {\"value\": 1, \"weight\": 1}]"
                        : "[{\"value\": 0, \"weight\": 98}, {\"value\": 1, \"weight\": 2}]";
  endfunction

  protected function string w_napot(int level);
    return "[{\"value\": 1, \"weight\": 1}, {\"value\": 0, \"weight\": 99}]";
  endfunction

  protected function string w_pbmt(int level);
    return (level >= 2)
      ? "[{\"value\": 0, \"weight\": 98}, {\"value\": 1, \"weight\": 1}, {\"value\": 2, \"weight\": 1}]"
      : "[{\"value\": 0, \"weight\": 96}, {\"value\": 1, \"weight\": 2}, {\"value\": 2, \"weight\": 2}]";
  endfunction

  // Append "<key>_level<N>": <weights> to a comma-separated attr list.
  protected function void add_attr(ref string attrs, input string key,
                                   input int level, input string weights);
    if (attrs.len() > 0) attrs = {attrs, ",\n            "};
    attrs = {attrs, $sformatf("\"%s_level%0d\": %s", key, level, weights)};
  endfunction

  protected virtual function string level_attrs(int level);
    string a = "";
    if (is_fault_selected(PT_FLT_VALID))    add_attr(a, "v", level, w_valid(level));
    if (is_fault_selected(PT_FLT_READ) ||
        is_fault_selected(PT_FLT_WRITE_NO_READ))
                                            add_attr(a, "r", level, w_adrwx(level));
    if (is_fault_selected(PT_FLT_WRITE) ||
        is_fault_selected(PT_FLT_WRITE_NO_READ))
                                            add_attr(a, "w", level, w_adrwx(level));
    if (is_fault_selected(PT_FLT_EXECUTE))  add_attr(a, "x", level, w_adrwx(level));
    if (is_fault_selected(PT_FLT_NAPOT))    add_attr(a, "n", level, w_napot(level));
    if (is_fault_selected(PT_FLT_ACCESSED)) add_attr(a, "a", level, w_adrwx(level));
    if (is_fault_selected(PT_FLT_DIRTY))    add_attr(a, "d", level, w_adrwx(level));
    if (is_fault_selected(PT_FLT_USER))     add_attr(a, "u", level, w_adrwx(level));
    if (is_fault_selected(PT_FLT_GLOBAL))   add_attr(a, "g", level, w_adrwx(level));
    if (is_fault_selected(PT_FLT_PBMT))     add_attr(a, "pbmt", level, w_pbmt(level));
    if (is_fault_selected(PT_FLT_RESERVED)) add_attr(a, "reserved", level, w_rsw_reserved(level));
    if (is_fault_selected(PT_FLT_RSW))      add_attr(a, "rsw", level, w_rsw_reserved(level));
    return a;
  endfunction

  // Override point: per-fault attribute keys. Empty => clean pages.
  protected virtual function string gen_fault_attrs();
    string attrs = "";
    string one;
    if (selected_faults.size() == 0) return "";
    for (int lvl = 0; lvl <= get_max_level(paging_mode); lvl++) begin
      one = level_attrs(lvl);
      if (one.len() == 0) continue;
      if (attrs.len() > 0) attrs = {attrs, ",\n            "};
      attrs = {attrs, one};
    end
    return attrs;
  endfunction

  // G-stage attrs are named per VS level AND G level: "<bit>_level<vs>_glevel<g>".
  protected function void add_g_attr(ref string attrs, input string key,
                                     input int vs_level, input int g_level,
                                     input string weights);
    if (attrs.len() > 0) attrs = {attrs, ",\n            "};
    attrs = {attrs, $sformatf("\"%s_level%0d_glevel%0d\": %s",
                              key, vs_level, g_level, weights)};
  endfunction

  protected virtual function string g_level_attrs(int vs_level, int g_level);
    string a = "";
    if (is_fault_selected(PT_FLT_G_VALID))    add_g_attr(a, "v", vs_level, g_level, w_valid(g_level));
    if (is_fault_selected(PT_FLT_G_READ))     add_g_attr(a, "r", vs_level, g_level, w_adrwx(g_level));
    if (is_fault_selected(PT_FLT_G_WRITE))    add_g_attr(a, "w", vs_level, g_level, w_adrwx(g_level));
    if (is_fault_selected(PT_FLT_G_EXECUTE))  add_g_attr(a, "x", vs_level, g_level, w_adrwx(g_level));
    if (is_fault_selected(PT_FLT_G_ACCESSED)) add_g_attr(a, "a", vs_level, g_level, w_adrwx(g_level));
    if (is_fault_selected(PT_FLT_G_DIRTY))    add_g_attr(a, "d", vs_level, g_level, w_adrwx(g_level));
    if (is_fault_selected(PT_FLT_G_USER))     add_g_attr(a, "u", vs_level, g_level, w_adrwx(g_level));
    if (is_fault_selected(PT_FLT_G_GLOBAL))   add_g_attr(a, "g", vs_level, g_level, w_adrwx(g_level));
    // reserved/rsw are part of the VS x G cross product: riemap indexes every
    // G-stage attribute by both levels ({base}_level<vs>_glevel<g>).
    if (is_fault_selected(PT_FLT_G_RESERVED))
      add_g_attr(a, "reserved", vs_level, g_level, w_rsw_reserved(g_level));
    if (is_fault_selected(PT_FLT_G_RSW))
      add_g_attr(a, "rsw", vs_level, g_level, w_rsw_reserved(g_level));
    return a;
  endfunction

  // Two-stage attrs: the VS-stage keys plus the G-stage VS x G cross product
  // (which now carries reserved/rsw too -- see g_level_attrs).
  protected virtual function string gen_ts_fault_attrs();
    string attrs = gen_fault_attrs();
    string one;
    int    gmax = get_max_level(gstage_paging_mode);
    if (gstage_paging_mode == MMUTB_PAGING_DISABLE) return attrs;

    for (int vs = 0; vs <= get_max_level(paging_mode); vs++)
      for (int g = 0; g <= gmax; g++) begin
        one = g_level_attrs(vs, g);
        if (one.len() == 0) continue;
        if (attrs.len() > 0) attrs = {attrs, ",\n            "};
        attrs = {attrs, one};
      end

    return attrs;
  endfunction

  function string get_selected_faults_str();
    string s = "";
    foreach (selected_faults[i])
      s = {s, (s == "") ? "" : ",", selected_faults[i].name()};
    return (s == "") ? "none" : s;
  endfunction

  // Override point: the "pages" array body.
  protected virtual function string page_groups();
    string attrs = gen_fault_attrs();
    string pages;
    pages = $sformatf({"        {\n          \"id\": \"single_stage_pages\",\n",
      "          \"num_pages\": %0d,\n          \"pa_and\": \"%s\",\n",
      "          \"attributes\": {\n            \"size\": [%s],\n            %s\n          }\n        }"},
      num_pages, pa_and, size_list(), (attrs == "") ? simple_attrs() : attrs);
    if (enable_fixed_global_pages && fixed_global_pages_json.len() > 0)
      pages = {fixed_global_pages_json, ",\n", pages};
    return pages;
  endfunction

  // Two-stage page group. riemap rejects the gstage_vs_* keys unless the
  // space declares twostage, so they appear only here.
  protected virtual function string ts_page_groups();
    string attrs = gen_ts_fault_attrs();
    return $sformatf({"        {\n          \"id\": \"twostage_pages\",\n",
      "          \"num_pages\": %0d,\n          \"pa_and\": \"%s\",\n",
      "          \"attributes\": {\n            \"size\": [%s],\n",
      "            \"gstage_vs_leaf_size\": \"%s\",\n",
      "            \"gstage_vs_nonleaf_size\": \"%s\",\n            %s\n          }\n        }"},
      twostage_num_pages, pa_and, size_list(),
      size_name(g_leaf_idx), size_name(g_nonleaf_idx),
      (attrs == "") ? simple_attrs() : attrs);
  endfunction

  protected function string space_single(string indent);
    return $sformatf({"%s\"twostage\": false,\n%s\"paging_mode\": \"%s\",\n",
                      "%s\"pages\": [\n%s\n%s]\n"},
      indent, indent, get_paging_mode_str(), indent, page_groups(), indent);
  endfunction

  protected function string space_twostage(string indent);
    return $sformatf({"%s\"twostage\": true,\n%s\"paging_mode\": \"%s\",\n",
                      "%s\"gstage_paging_mode\": \"%s\",\n%s\"pages\": [\n%s\n%s]\n"},
      indent, indent, get_paging_mode_str(), indent, gmode_str(), indent, ts_page_groups(), indent);
  endfunction

  virtual function string to_json();
    string spaces;
    string ind = "      ";
    if (mixed_mode)
      spaces = {"    \"space1\": {\n", space_single(ind), "    },\n",
                "    \"space2\": {\n", space_twostage(ind), "    }\n"};
    else if (twostage)
      spaces = {"    \"space1\": {\n", space_twostage(ind), "    }\n"};
    else
      spaces = {"    \"space1\": {\n", space_single(ind), "    }\n"};

    return $sformatf({"{\n  \"mmap\": [[\"%s\", \"%s\"]],\n  \"spaces\": {\n%s  }\n}\n"},
                     mmap_lo, mmap_hi, spaces);
  endfunction

  virtual function void print_config();
    `uvm_info("PT_CFG_BASE", "--- PT config ---", UVM_LOW)
    `uvm_info("PT_CFG_BASE", $sformatf("  mode      : %s", get_paging_mode_str()), UVM_LOW)
    `uvm_info("PT_CFG_BASE", $sformatf("  num_pages : %0d", num_pages), UVM_LOW)
    `uvm_info("PT_CFG_BASE", $sformatf("  sizes     : %s", plain_size_list()), UVM_LOW)
    `uvm_info("PT_CFG_BASE", $sformatf("  weights   : %s", size_list()), UVM_LOW)
    `uvm_info("PT_CFG_BASE", $sformatf("  asid      : 0x%04h", asid), UVM_LOW)
    `uvm_info("PT_CFG_BASE", $sformatf("  mmap      : %s..%s pa_and=%s",
              mmap_lo, mmap_hi, pa_and), UVM_LOW)
    `uvm_info("PT_CFG_BASE", $sformatf("  faults    : %0d [%s]",
              selected_faults.size(), get_selected_faults_str()), UVM_LOW)
    `uvm_info("PT_CFG_BASE", $sformatf("  variant   : %s",
              mixed_mode ? "mixed" : (twostage ? "two_stage" : "single")), UVM_LOW)
    if (twostage)
      `uvm_info("PT_CFG_BASE", $sformatf("  gstage    : %s ts_pages=%0d gleaf=%s gnonleaf=%s",
                (gstage_paging_mode == MMUTB_PAGING_DISABLE) ? "disabled" : gmode_str(),
                twostage_num_pages, size_name(g_leaf_idx), size_name(g_nonleaf_idx)), UVM_LOW)
  endfunction

endclass : mmu_pt_config_gen_base

`endif // MMU_PT_CONFIG_GEN_BASE_SV
