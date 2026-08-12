// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_ifu_translate_seq.sv
//
// Drives a list of fetch VAs through the IFU translation port and self-
// checks each returned physical page against the loader's golden map.
//
// Sequence-local self-check: for a mapped VA the DUT must
// return pavld=1, pgflt=0, and mmu_ifu_pa == expected_pa >> 12, where
// expected_pa is (page_base_pa + in-page offset). The `va_map` (VA, PA,
// page_kb) is optional: the scoreboard is the authority on PA correctness.
//======================================================================

`ifndef MMU_IFU_TRANSLATE_SEQ_SV
`define MMU_IFU_TRANSLATE_SEQ_SV

class mmu_ifu_translate_seq extends uvm_sequence #(mmu_ifu_seq_item);
  `uvm_object_utils(mmu_ifu_translate_seq)

  // Golden map, set by the test before start().
  mmu_common_pkg::mmu_va_map_t va_map[$];

  // How many mappings to exercise (0 = all).
  int unsigned max_vas = 8;

  // Number of times to drive the whole VA list. The first pass warms the TLBs
  // (each fresh page misses -> full walk); later passes hit the I-uTLB and
  // stream back-to-back at 1/cycle (exercises the pipelined driver + monitor).
  int unsigned num_passes = 1;

  // When 1 (default), check the returned PA against the golden map. When 0
  // (in-sim PageTableSV path, which has no golden PA), check only that the
  // fetch translates (pavld=1, pgflt=0); the scoreboard owns the PA compare.
  bit check_pa = 1'b1;

  // Percent of requests issued as speculative (front-end flow change). If such a
  // request misses, the driver abandons it via ifu_mmu_abort (no response owed);
  // if it hits, it completes normally.
  int unsigned spec_pct = 5;

  // Non-canonical VA injection: ~1-in-noncanon_va_1in fetches get a non-canonical
  // Sv39 VA -> IUTLB page fault (Case B match). 0 disables; 200 = ~0.5%. Applied
  // only in scoreboard mode (check_pa=0).
  int unsigned noncanon_va_1in = 200;

  int unsigned pass_cnt;
  int unsigned fail_cnt;
  int unsigned abandon_cnt;
  int unsigned canon_cnt;

  function new(string name = "mmu_ifu_translate_seq");
    super.new(name);
  endfunction

  virtual task body();
    int unsigned n = (max_vas == 0) ? va_map.size() :
                     (max_vas < va_map.size() ? max_vas : va_map.size());

    for (int unsigned pass = 0; pass < num_passes; pass++) begin
      foreach (va_map[i]) begin
        longint unsigned exp_pa;
        bit [27:0]       exp_ppn;
        longint unsigned byte_va;
        mmu_ifu_seq_item req;

        if (i >= n) break;

        exp_pa  = va_map[i].pa;               // page-aligned base PA for this VA
        exp_ppn = exp_pa[39:12];              // expected mmu_ifu_pa

        req = mmu_ifu_seq_item::type_id::create($sformatf("ifu_p%0d_%0d", pass, i));
        start_item(req);
        // ifu_mmu_va is VA[63:1] (IUTLB reads the VPN from VA[38:12]); drive VA >> 1.
        // ~1/noncanon_va_1in fetches get a non-canonical VA (scoreboard mode only).
        byte_va = va_map[i].va;
        if (!check_pa && noncanon_va_1in != 0 && $urandom_range(0, noncanon_va_1in-1) == 0) begin
          byte_va = mmu_common_pkg::mmu_bad_va_sv39(byte_va);
          canon_cnt++;
        end
        req.va          = byte_va[63:1];
        req.abort       = 1'b0;
        // ~spec_pct% of fetches are speculative (may be abandoned on a miss).
        req.speculative = ($urandom_range(1, 100) <= spec_pct);
        finish_item(req);                     // driver captures the response

        if (req.speculative && req.abandoned) begin
          // Speculative miss abandoned via abort — no response owed, not a fail.
          abandon_cnt++;
          `uvm_info("IFU_CHK",
            $sformatf("ABANDON va=0x%0h (speculative miss cancelled via abort)", va_map[i].va),
            UVM_MEDIUM)
        end
        else if (!check_pa) begin
          // Scoreboard-authoritative mode: any response (success OR fault) is
          // "handled" here — the mmu_scoreboard checks it against Whisper
          // (success -> PA compare; fault -> fault-kind compare). We only fail
          // if the DUT never responded at all.
          if (req.pavld === 1'b1) begin
            pass_cnt++;
            `uvm_info("IFU_CHK",
              $sformatf("RESP va=0x%0h -> %s (checked by scoreboard)", va_map[i].va,
                        (req.pgflt || req.deny) ?
                          $sformatf("FAULT(pgflt=%0b deny=%0b)", req.pgflt, req.deny) :
                          $sformatf("ppn=0x%0h", req.pa)), UVM_MEDIUM)
          end
          else begin
            fail_cnt++;
            `uvm_error("IFU_CHK",
              $sformatf("FAIL va=0x%0h: no response (pavld=0)", va_map[i].va))
          end
        end
        else if (req.pavld === 1'b1 && req.pgflt === 1'b0 && req.pa === exp_ppn) begin
          pass_cnt++;
          `uvm_info("IFU_CHK",
            $sformatf("PASS va=0x%0h -> pa_ppn=0x%0h (exp 0x%0h)", va_map[i].va, req.pa, exp_ppn),
            UVM_MEDIUM)
        end
        else begin
          fail_cnt++;
          `uvm_error("IFU_CHK",
            $sformatf("FAIL va=0x%0h: got pavld=%0b pgflt=%0b pa_ppn=0x%0h, exp pavld=1 pgflt=0 pa_ppn=0x%0h",
                      va_map[i].va, req.pavld, req.pgflt, req.pa, exp_ppn))
        end
      end
    end

    `uvm_info("IFU_CHK",
      $sformatf("IFU translate summary: %0d pass, %0d fail, %0d abandoned, %0d non-canonical injected",
                pass_cnt, fail_cnt, abandon_cnt, canon_cnt), UVM_LOW)
  endtask

endclass : mmu_ifu_translate_seq

`endif // MMU_IFU_TRANSLATE_SEQ_SV
