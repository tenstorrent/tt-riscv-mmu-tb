// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_base_seq.sv
//
// In-sim page-table generation base sequence. A VIRTUAL SEQUENCE run on
// mmu_virtual_sequencer, owning the page-table lifecycle for a test:
//
//   1. construct PageTableSV (pysv DPI -> embedded riescue generator),
//   2. generate (from a config JSON) or load (from a pre-gen output.json),
//   3. pull the PTEs and VAs back over DPI in 500-entry batches,
//   4. preload the PTEs into the shared mmu_sysmem (backdoor, LE),
//   5. extract satp (mode + PPN) and program it via the CSR agent, and
//   6. drive translations (overridable hook).
//
// This replaces the offline flat-file flow (pt_json_to_tb.py + a flat-file
// loader) with live in-sim generation.
//
// Collaborators come from p_sequencer (connected by the env):
//   p_sequencer.mem       - shared physical memory to preload
//   p_sequencer.csr_sqr   - CSR/CP0 sequencer, for satp programming
//   p_sequencer.ifu_sqr   - IFU sequencer, for driving translations
//
// Plusargs:
//   +PT_OUTPUT_JSON=<file>  load a pre-generated output.json (takes precedence)
//   +PT_CONFIG_JSON=<file>  generate from a riescue config JSON
//   +PT_SEED=<n>            generation seed (default 1)
//   +PT_SPACE_ID=<id>       which space to load from output.json (default: all)
//
// Note: PageTableSV's batch API returns VAs but NOT expected PAs, so PA
// correctness is scored by the Whisper reference model in mmu_scoreboard --
// the unit sequences themselves only check that translation succeeded
// (pavld=1, pgflt=0) and leave the PA compare to the scoreboard.
//======================================================================

`ifndef MMU_BASE_SEQ_SV
`define MMU_BASE_SEQ_SV

class mmu_base_seq extends uvm_sequence;
  `uvm_object_utils(mmu_base_seq)
  `uvm_declare_p_sequencer(mmu_virtual_sequencer)

  // ---- pysv page-table generator (embedded riescue) ----
  PageTableSV_pkg::PageTableSV page_table_sv;

  // ---- parsed page table, pulled back over DPI ----
  typedef struct {
    longint unsigned addr;
    longint unsigned data;
  } pte_entry_t;

  typedef struct {
    longint unsigned va;
    bit              is_virtual;
  } va_entry_t;

  pte_entry_t pte_entries[$];
  va_entry_t  va_entries[$];

  // ---- extracted satp ----
  bit [27:0] satp_ppn;
  string     satp_mode;   // "SV39", "BARE", ...
  bit [15:0] gen_asid = 16'h100;   // ASID for satp (randomized when +PT_DYNAMIC)

  // Total translations to DRIVE per interface:
  // requests are NOT one-per-generated-VA -- the drive loop picks VAs from the
  // pool WITH REPLACEMENT, so num_of_reqs can far exceed the pool size and
  // repeated VAs exercise real TLB hit/reuse/eviction traffic. 0 => randomize
  // per resolve_num_reqs() below. Override with +MMU_NUM_REQS=<n>.
  int unsigned num_of_reqs = 0;

  // Per-priv-batch request count -- how many requests before re-randomizing
  // the privilege mode:
  // privilege is re-randomized every this-many requests. ~300-400 per batch.
  int unsigned batch_lo = 300;
  int unsigned batch_hi = 400;

  // Resolve the total request count: +MMU_NUM_REQS plusarg wins, else the
  // caller-set num_of_reqs, else a randomized 600..800. Capped at 600-800 (not
  // deliberately small) to keep the Verilator UVM runtime reasonable for the
  // per-MR smoke; VAs are still driven WITH REPLACEMENT so this exceeds the pool
  // and exercises TLB reuse. Override with +MMU_NUM_REQS=<n> for longer runs.
  protected function int unsigned resolve_num_reqs();
    int unsigned v;
    if ($value$plusargs("MMU_NUM_REQS=%d", v)) return v;
    if (num_of_reqs != 0)                      return num_of_reqs;
    return $urandom_range(600, 800);
  endfunction

  // Randomize the data-path permission CSRs SUM/MXR (+MMUTB_EN_CSR_RAND
  // gate, 70/30 off/on, default off). Whisper's DvMmu exposes no SUM/MXR setter, so
  // it always runs (0,0); the scoreboard folds the resulting Whisper-fault/DUT-success
  // in Case D. MXR: read of an X-only leaf. SUM: S-mode access to a U=1 leaf.
  protected function void rand_sum_mxr(output bit mxr_v, output bit sum_v);
    mxr_v = 1'b0;
    sum_v = 1'b0;
    if (!$test$plusargs("MMUTB_EN_CSR_RAND")) return;
    if (!std::randomize(mxr_v, sum_v) with {
          mxr_v dist { 0 := 70, 1 := 30 };
          sum_v dist { 0 := 70, 1 := 30 };
        })
      `uvm_error("MMU_BASE_SEQ", "SUM/MXR randomize() failed")
  endfunction

  // Number of passes over the VA list.
  int unsigned num_passes = 1;

  // When set, body() skips shared setup (generate/preload/program-satp) and
  // only drives stimulus -- used when a PARENT sequence (e.g. mmu_ifu_lsu_seq)
  // already did the one-time setup and forks this seq's drive phase.
  bit skip_setup = 1'b0;

  // Apply a randomized, PT-window-aware PMP config as part of the common setup
  // so EVERY test (IFU/LSU/combined) exercises PMP -- PMP is
  // common stimulus, not a dedicated test. Default on; a parent that owns PMP
  // itself (or a test that wants all-permissive) can clear it. +PMP_OFF forces
  // it off. The PT window (PPN units) bounds the random regions to real memory.
  bit               pmp_rand_en   = 1'b1;
  localparam bit [27:0] PMP_WIN_LO_PPN = 28'h0_0080000;   // 0x80000000 >> 12
  localparam bit [28:0] PMP_WIN_HI_PPN = 29'h1000_0000;   // 2^40 >> 12

  // Batch the DPI string transfer to avoid string-size limits.
  localparam int BATCH_SIZE = 500;

  //--------------------------------------------------------------------
  // Dynamic-satp hooks (used by mmu_dynamic_satp_seq for mid-run context
  // switches). Defaults keep the base flow unchanged.
  //--------------------------------------------------------------------
  // Per-switch PT seed: when has_ctx_seed, generate_page_tables() uses ctx_seed
  // instead of +PT_SEED so each switch builds a different page table.
  bit               has_ctx_seed = 1'b0;
  int unsigned      ctx_seed     = 0;
  // Force a specific ASID (context swap): when set, gen_asid is overridden after
  // the config randomize (so satp + INV_ASID line up on a chosen ASID).
  bit               force_asid_en = 1'b0;
  bit [15:0]        forced_asid   = 16'h0;
  // Ask program_satp() to quiesce the MMU before the CTX_SET (dynamic switch).
  bit               satp_wait_idle = 1'b0;
  // Dynamic-satp: prepend the fixed global-page group to each generated context
  // (set by mmu_dynamic_satp_seq under +MMU_SATP_ENABLE_GLOBAL_PAGES).
  bit               use_global_pages = 1'b0;
  // Count of PT generations in this run (0-based). Used to write per-context
  // config/output JSON files so every context is preserved (not overwritten).
  static int        pt_gen_count = 0;

  function new(string name = "mmu_base_seq");
    super.new(name);
  endfunction

  // Orchestrate: generate -> preload -> program satp -> drive.
  virtual task body();
    if (!skip_setup) begin
      generate_page_tables();
      preload_ptes();
      program_satp();
      program_pmp();
    end
    drive_stimulus();   // override in derived tests
  endtask

  // Randomize + apply one PT-window-aware PMP config through the PMP agent, so
  // every test runs with a real (non-permissive) PMP. Skipped when pmp_rand_en
  // is cleared or +PMP_OFF is set (leaves the reset all-permissive default).
  virtual task program_pmp();
    mmu_pmp_config     cfg;
    mmu_pmp_apply_seq  aseq;
    if (!pmp_rand_en || $test$plusargs("PMP_OFF")) return;
    if (p_sequencer.pmp_sqr == null)
      `uvm_fatal("MMU_BASE_SEQ", "p_sequencer.pmp_sqr is null (env must connect vseqr.pmp_sqr)")
    cfg = mmu_pmp_config::type_id::create("pmp_cfg");
    cfg.win_lo_ppn = {1'b0, PMP_WIN_LO_PPN};
    cfg.win_hi_ppn = PMP_WIN_HI_PPN;
    // Anchor PMP regions on PPNs this run actually translates to, taken from
    // the generated leaf PTEs (data[37:10] = target PPN). Random addr[] alone
    // never overlaps live traffic, so PMP would only ever be exercised via the
    // no-match default.
    begin
      int n = 0;
      bit is_pt[bit [27:0]];    // PPNs holding page tables -- never anchor on these
      foreach (pte_entries[i]) is_pt[pte_entries[i].addr[39:12]] = 1'b1;
      foreach (pte_entries[i]) begin
        bit [63:0] pte = pte_entries[i].data;
        bit [27:0] base;
        if (n >= mmu_pmp_config::NUM_ANCHORS) break;
        if (!(pte[0] && (pte[1] || pte[3]))) continue;    // valid leaf (R or X) only
        base = pte[37:10] & ~28'h1;                       // 2-PPN NAPOT [base, base+2)
        // A deny anchor overlapping a page table would abort the WALK (that is
        // what NAPOT_SIZE_CAP_BIT guards against), so skip those PPNs entirely.
        if (is_pt.exists(base) || is_pt.exists(base + 28'd1)) continue;
        cfg.anchors[n] = base;
        n++;
      end
      cfg.anchor_en = (n == mmu_pmp_config::NUM_ANCHORS);
    end
    if (!cfg.randomize())   // post_randomize() computes lo/hi/vld
      `uvm_fatal("MMU_BASE_SEQ", "PMP config randomize() failed")
    aseq = mmu_pmp_apply_seq::type_id::create("pmp_apply");
    aseq.cfg = cfg;
    aseq.start(p_sequencer.pmp_sqr);
    `uvm_info("MMU_BASE_SEQ", "applied randomized PMP config (base flow)", UVM_LOW)
  endtask

  //--------------------------------------------------------------------
  // 1-3) construct + generate/load + pull PTE/VA batches
  //--------------------------------------------------------------------
  virtual task generate_page_tables();
    int    num_entries;
    string cfg_json;
    string out_json;
    string space_id;
    int    seed = 1;

    if (page_table_sv == null)
      page_table_sv = new();

    void'($value$plusargs("PT_SEED=%d", seed));
    // Dynamic-satp: each switch overrides the seed so it builds a fresh PT.
    if (has_ctx_seed) seed = ctx_seed;

    if ($value$plusargs("PT_OUTPUT_JSON=%s", out_json)) begin
      if (!$value$plusargs("PT_SPACE_ID=%s", space_id)) space_id = "";
      `uvm_info("MMU_BASE_SEQ",
        $sformatf("loading page tables from %s (space='%s')", out_json, space_id), UVM_LOW)
      num_entries = page_table_sv.load_page_tables_from_output(out_json, space_id);
    end
    else if ($test$plusargs("PT_DYNAMIC")) begin
      num_entries = generate_from_dynamic_cfg(seed);
    end
    else if ($value$plusargs("PT_CONFIG_JSON=%s", cfg_json)) begin
      `uvm_info("MMU_BASE_SEQ",
        $sformatf("generating page tables from %s (seed=%0d)", cfg_json, seed), UVM_LOW)
      num_entries = page_table_sv.generate_page_tables_from_json(cfg_json, seed);
    end
    else begin
      `uvm_fatal("MMU_BASE_SEQ",
        "no page-table source: set +PT_DYNAMIC, +PT_CONFIG_JSON=<cfg>, or +PT_OUTPUT_JSON=<out>")
    end

    if (num_entries < 0)
      `uvm_fatal("MMU_BASE_SEQ", "PageTableSV generation/load failed (returned <0)")

    pull_pte_batches();
    pull_va_batches();

    satp_ppn  = page_table_sv.get_satp_ppn();
    satp_mode = page_table_sv.get_satp_paging_mode();
    `uvm_info("MMU_BASE_SEQ",
      $sformatf("generated %0d PTEs, %0d VAs; satp mode=%s ppn=0x%0h",
                pte_entries.size(), va_entries.size(), satp_mode, satp_ppn), UVM_LOW)
  endtask

  //--------------------------------------------------------------------
  // +PT_DYNAMIC source: randomize a C910-safe config in SV (Sv39,
  // single-stage, PA bounded, no N/PBMT), emit its JSON and generate from that
  // string, then hand that to generate_page_tables_from_config_str.
  // Returns the PTE count from the generator (<0 on failure).
  //
  // Fault selection (dynamic randomizes fault-or-no-fault BY DEFAULT, like
  // some seeds inject 0-2 C910-valid faults, others are clean):
  //   +PT_NO_FAULT            force a clean config
  //   +PT_FAULTS              force >=1 fault, type(s) randomly picked
  //   +PT_FAULTS=NOEXEC,USER  force exactly those types
  //--------------------------------------------------------------------
  protected virtual function int generate_from_dynamic_cfg(int seed);
    string            ft_str;
    string            cfg_json;
    int               num_entries;
    mmu_pt_config_gen cfg = mmu_pt_config_gen::type_id::create("cfg");

    // Seed the SV randomization from PT_SEED so different seeds yield different
    // configs (reproducibly), matching the riemap seed.
    cfg.srandom(seed);

    if ($test$plusargs("PT_NO_FAULT"))
      cfg.force_no_fault = 1'b1;
    if ($test$plusargs("PT_FAULTS")) begin
      cfg.force_faults = 1'b1;
      // "1"/"on"/"yes" are NOT fault names; only treat other values as a list.
      if ($value$plusargs("PT_FAULTS=%s", ft_str) && ft_str.len() > 0 &&
          ft_str != "1" && ft_str.tolower() != "on" && ft_str.tolower() != "yes")
        cfg.set_forced_faults(ft_str);
    end

    if (!cfg.randomize())
      `uvm_fatal("MMU_BASE_SEQ", "mmu_pt_config_gen randomize() failed")
    cfg.print_summary();

    gen_asid = cfg.asid;
    // Dynamic-satp: override the ASID with a chosen one (context swap) so the
    // satp write and any INV_ASID target the same ASID.
    if (force_asid_en) gen_asid = forced_asid;
    // Dynamic-satp: prepend the fixed global pages so the same g=1 set exists
    // in every context (persists across switches, survives INV_ASID).
    if (use_global_pages) begin
      cfg.enable_fixed_global_pages = 1'b1;
      cfg.fixed_global_pages_json   = get_global_pages_json();
    end

    cfg_json = cfg.to_json();
    dump_cfg_json(cfg_json, seed);

    // Pass the context index as switch_num so the bridge writes a per-context
    // output file (generated_pt_output_switch_<n>.json for n>0; the base
    // context n=0 -> generated_pt_output.json). Every output is preserved.
    num_entries = page_table_sv.generate_page_tables_from_config_str(
                    cfg_json, seed, pt_gen_count, 0, 0);
    pt_gen_count++;
    return num_entries;
  endfunction

  //--------------------------------------------------------------------
  // Save the generated INPUT config alongside riemap' output (mirrors
  // input + output both kept). A run can generate MANY contexts
  // (dynamic satp regenerates per switch), so every context is APPENDED to one
  // generated_pt_config.log with a header rather than overwriting a .json.
  //--------------------------------------------------------------------
  protected virtual function void dump_cfg_json(string cfg_json, int seed);
    int fd;
    // First generation truncates the combined file; later ones append.
    fd = $fopen("generated_pt_config.log", (pt_gen_count == 0) ? "w" : "a");
    if (fd) begin
      $fwrite(fd, "// ===== context %0d (seed=%0d) =====\n%s\n",
              pt_gen_count, seed, cfg_json);
      $fclose(fd);
    end
    `uvm_info("MMU_BASE_SEQ",
      $sformatf("dynamic PT config (context=%0d seed=%0d) -> appended to generated_pt_config.log",
                pt_gen_count, seed), UVM_LOW)
  endfunction

  // Pull PTEs in batches: "addr:data,addr:data,..." (hex). Empty => done.
  virtual task pull_pte_batches();
    string s;
    int    idx = 0;
    pte_entries.delete();
    do begin
      s = page_table_sv.get_ptes_batch(idx, BATCH_SIZE);
      parse_ptes(s);
      idx++;
    end while (s.len() > 0);
  endtask

  // Pull VAs in batches: "va:is_virtual,va:is_virtual,..." (hex). Empty => done.
  virtual task pull_va_batches();
    string s;
    int    idx = 0;
    va_entries.delete();
    do begin
      s = page_table_sv.get_vas_batch(idx, BATCH_SIZE);
      parse_vas(s);
      idx++;
    end while (s.len() > 0);
  endtask

  //--------------------------------------------------------------------
  // 4) preload PTEs into the shared physical memory (sysmem, backdoor,
  //    little-endian). No page scrub needed: sysmem returns 0 for unwritten
  //    locations, so PT pages start clean and the PTW sees invalid entries.
  //--------------------------------------------------------------------
  virtual function void preload_ptes();
    if (p_sequencer.mem == null)
      `uvm_fatal("MMU_BASE_SEQ", "p_sequencer.mem is null (env must connect vseqr.mem)")
    foreach (pte_entries[i]) begin
      p_sequencer.mem.write_8(pte_entries[i].addr, pte_entries[i].data);
      // Mirror the PTE into the Whisper reference model so it walks the same
      // page tables as the DUT (the scoreboard compares against Whisper).
      if (p_sequencer.wh != null)
        void'(p_sequencer.wh.mem_write(pte_entries[i].addr, 8, pte_entries[i].data));
    end
    `uvm_info("MMU_BASE_SEQ",
      $sformatf("preloaded %0d PTEs into sysmem%s", pte_entries.size(),
                (p_sequencer.wh != null) ? " + Whisper" : ""), UVM_LOW)
  endfunction

  // Fixed global pages: generate NUM_GLOBAL
  // pages ONCE (g=1,a=1,d=1; randomized VA/PA/size 4K/2M/1G; VA-overlap checked;
  // seeded from PT_SEED for per-run reproducibility) and cache the JSON so the
  // SAME global set is prepended to EVERY context's page list -- global = maps
  // in all address spaces, so it must persist across satp switches (and survive
  // INV_ASID, cleared only by INV_ALL). Static so it's stable across regens.
  static string global_pages_json = "";
  static bit    global_pages_done = 1'b0;
  localparam int unsigned NUM_GLOBAL = 10;

  function string get_global_pages_json();
    longint unsigned page_sizes[3] = '{ 'h1000, 'h200000, 'h40000000 };  // 4K/2M/1G
    string           size_strs[3]  = '{ "4kb", "2mb", "1gb" };
    longint unsigned va_min = 'h0000_0000_0010_0000;  // 1MB
    longint unsigned va_max = 'h0000_003F_FFFF_FFFF;  // Sv39 canonical max
    longint unsigned pa_min = 'h0000_0000_8000_0000;  // 2GB (C910 window)
    longint unsigned pa_max = 'h0000_0008_0000_0000;  // 32GB
    longint unsigned va_lo_list[$], va_hi_list[$];
    int    seed = 1, made = 0;
    string json = "";

    if (global_pages_done) return global_pages_json;
    void'($value$plusargs("PT_SEED=%d", seed));
    process::self().srandom(seed + 12345);   // offset from the PT randomization

    for (int att = 0; att < 100 && made < NUM_GLOBAL; att++) begin
      int              rv = $urandom_range(0, 99);
      int              si = (rv < 55) ? 0 : (rv < 85) ? 1 : 2;  // 55% 4K / 30% 2M / 15% 1G
      longint unsigned psz = page_sizes[si];
      longint unsigned va, pa, vlo, vhi;
      bit              overlap = 1'b0;
      va = $urandom_range(va_min/psz, (va_max-psz)/psz) * psz;   // page-aligned
      vlo = va; vhi = va + psz - 1;
      foreach (va_lo_list[i])
        if (vlo <= va_hi_list[i] && vhi >= va_lo_list[i]) begin overlap = 1'b1; break; end
      if (overlap) continue;
      pa = $urandom_range(pa_min/psz, (pa_max-psz)/psz) * psz;
      va_lo_list.push_back(vlo); va_hi_list.push_back(vhi);
      if (made > 0) json = {json, ",\n"};
      json = {json, $sformatf({"        {\n          \"id\": \"global_page_%0d\",\n",
        "          \"num_pages\": 1,\n          \"va\": \"0x%0h\",\n          \"pa\": \"0x%0h\",\n",
        "          \"attributes\": {\n            \"size\": \"%s\",\n            \"a\": 1,\n",
        "            \"d\": 1,\n            \"g\": 1\n          }\n        }"},
        made, va, pa, size_strs[si])};
      made++;
    end
    global_pages_json = json;
    global_pages_done = 1'b1;
    `uvm_info("MMU_BASE_SEQ", $sformatf("generated %0d fixed global pages (g=1)", made), UVM_LOW)
    return global_pages_json;
  endfunction

  // Dynamic-satp: zero the CURRENT context's PTEs out of sysmem + Whisper
  // before regenerating a new context, so a reused physical page can't alias an
  // old mapping. Global (persistent) pages, if any, are re-preloaded by the
  // caller after regen. Call BEFORE generate_page_tables() overwrites
  // pte_entries.
  virtual function void clear_old_ptes();
    if (p_sequencer.mem == null) return;
    foreach (pte_entries[i]) begin
      p_sequencer.mem.write_8(pte_entries[i].addr, 64'h0);
      if (p_sequencer.wh != null)
        void'(p_sequencer.wh.mem_write(pte_entries[i].addr, 8, 64'h0));
    end
    `uvm_info("MMU_BASE_SEQ",
      $sformatf("cleared %0d old PTEs from sysmem%s", pte_entries.size(),
                (p_sequencer.wh != null) ? " + Whisper" : ""), UVM_LOW)
  endfunction

  //--------------------------------------------------------------------
  // 5) program satp via the CSR agent (reuses mmu_csr_cfg_seq)
  //--------------------------------------------------------------------
  virtual task program_satp();
    mmu_csr_cfg_seq cfg;
    if (p_sequencer.csr_sqr == null)
      `uvm_fatal("MMU_BASE_SEQ", "p_sequencer.csr_sqr is null (env must connect vseqr.csr_sqr)")
    cfg = mmu_csr_cfg_seq::type_id::create("cfg");
    cfg.satp_ppn   = satp_ppn;
    cfg.sv39_en    = (satp_mode == "SV39");
    cfg.asid       = gen_asid;
    cfg.wait_idle  = satp_wait_idle;   // dynamic-satp: quiesce before the swap
    cfg.start(p_sequencer.csr_sqr);

    // Program the Whisper reference model's satp to match (mode + root PPN),
    // so it walks with the same translation context as the DUT.
    if (p_sequencer.wh != null) begin
      p_sequencer.wh.config_translation(
        (satp_mode == "SV39") ? DV_MMU_MODE_SV39 : DV_MMU_MODE_BARE,
        cfg.asid, satp_ppn);
      // C910 has no hardware A/D update: it page-faults on a leaf with A=0, and
      // on a store to a leaf with D=0. Make Whisper fault the same way so the
      // scoreboard matches (this would normally come from HADE/SVADU; C910 has no
      // Svadu, so it is simply always on).
      p_sequencer.wh.set_fault_on_first_access(1'b1);
    end

    // Publish the satp context so the scoreboard's SV page-table walker (which
    // scores per-PTE-read PMP) can walk from the same root PPN / mode.
    uvm_config_db#(bit [27:0])::set(null, "*", "satp_root_ppn", satp_ppn);
    uvm_config_db#(bit)::set(null, "*", "satp_sv39", (satp_mode == "SV39"));
  endtask

  //--------------------------------------------------------------------
  // 6) drive translations. Reuses mmu_ifu_translate_seq in success-only mode
  //    (check_pa=0): PageTableSV supplies VAs but no golden PA, so we verify
  //    only that each fetch translates (pavld=1, pgflt=0); the scoreboard owns
  //    the PA compare against Whisper. Override in derived tests.
  //--------------------------------------------------------------------
  // Stimulus hook. The base sequence only sets up translation context
  // (generate -> preload -> program satp); it drives NO per-unit stimulus.
  // Unit sequences (mmu_ifu_seq, later mmu_lsu_seq) extend this and override
  // drive_stimulus() to drive their interface: the per-unit sequences extend
  // this class and override only the driving phase.
  virtual task drive_stimulus();
    // no-op in the base
  endtask

  //--------------------------------------------------------------------
  // batch-string parsing helpers:
  // split the comma-separated batch with uvm_split_string, then split each
  // "addr:data" / "va:is_virtual" entry on the colon. $sscanf("%h") parses
  // the full 64-bit hex value (string::atohex() is only 32-bit, so NOT used).
  //--------------------------------------------------------------------
  protected function void parse_ptes(string s);
    string      entries[$];
    string      addr_str, data_str;
    int         colon_pos;
    pte_entry_t e;
    if (s.len() == 0) return;
    uvm_split_string(s, ",", entries);
    foreach (entries[i]) begin
      // Find the colon separating addr:data.
      colon_pos = -1;
      for (int j = 0; j < entries[i].len(); j++)
        if (entries[i].getc(j) == ":") begin colon_pos = j; break; end
      if (colon_pos > 0) begin
        addr_str = entries[i].substr(0, colon_pos - 1);
        data_str = entries[i].substr(colon_pos + 1, entries[i].len() - 1);
        void'($sscanf(addr_str, "%h", e.addr));
        void'($sscanf(data_str, "%h", e.data));
        pte_entries.push_back(e);
      end
    end
  endfunction

  protected function void parse_vas(string s);
    string     entries[$];
    string     va_str, virt_str;
    int        colon_pos;
    va_entry_t e;
    if (s.len() == 0) return;
    uvm_split_string(s, ",", entries);
    foreach (entries[i]) begin
      // Find the colon separating va:is_virtual.
      colon_pos = -1;
      for (int j = 0; j < entries[i].len(); j++)
        if (entries[i].getc(j) == ":") begin colon_pos = j; break; end
      if (colon_pos > 0) begin
        va_str   = entries[i].substr(0, colon_pos - 1);
        virt_str = entries[i].substr(colon_pos + 1, entries[i].len() - 1);
        void'($sscanf(va_str, "%h", e.va));
        e.is_virtual = (virt_str == "1");
        va_entries.push_back(e);
      end
    end
  endfunction

endclass : mmu_base_seq

`endif // MMU_BASE_SEQ_SV
