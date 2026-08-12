// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_lsu_translate_seq.sv
//
// Drives a list of data VAs through the LSU translation port. Load vs store is
// chosen per request from store_pct. Scoreboard-authoritative: any DUT response
// (valid PA OR fault) is "handled" here — the mmu_scoreboard does the real
// DUT-vs-Whisper compare (success -> PA; fault -> fault-kind). We only fail if
// the DUT never responds.
//
// The full 64-bit byte VA is driven (the duTLB reads vpn = va[38:12]); no >>1.
//======================================================================
`ifndef MMU_LSU_TRANSLATE_SEQ_SV
`define MMU_LSU_TRANSLATE_SEQ_SV

class mmu_lsu_translate_seq extends uvm_sequence #(mmu_lsu_seq_item);
  `uvm_object_utils(mmu_lsu_translate_seq)

  // VA pool, set by the unit sequence before start() (pa/page_kb unused in-sim).
  mmu_common_pkg::mmu_va_map_t va_map[$];

  int unsigned max_vas    = 64;   // how many VAs to exercise (0 = all)
  int unsigned num_passes = 1;    // passes over the VA list (later passes warm)
  int unsigned store_pct  = 0;    // percent of accesses issued as stores

  int unsigned pass_cnt;
  int unsigned fail_cnt;

  function new(string name = "mmu_lsu_translate_seq");
    super.new(name);
  endfunction

  virtual task body();
    int unsigned n = (max_vas == 0) ? va_map.size() :
                     (max_vas < va_map.size() ? max_vas : va_map.size());

    for (int unsigned pass = 0; pass < num_passes; pass++) begin
      foreach (va_map[i]) begin
        mmu_lsu_seq_item req;
        if (i >= n) break;

        req = mmu_lsu_seq_item::type_id::create($sformatf("lsu_p%0d_%0d", pass, i));
        start_item(req);
        req.va      = va_map[i].va;                            // full byte VA
        req.st_inst = ($urandom_range(1, 100) <= store_pct);
        finish_item(req);                                      // driver captures response

        if (req.pa_vld === 1'b1 || req.page_fault === 1'b1 || req.access_fault === 1'b1) begin
          pass_cnt++;
          `uvm_info("LSU_CHK",
            $sformatf("RESP %s va=0x%0h -> %s (checked by scoreboard)",
                      req.st_inst ? "ST" : "LD", va_map[i].va,
                      (req.page_fault || req.access_fault) ?
                        $sformatf("FAULT(pg=%0b acc=%0b)", req.page_fault, req.access_fault) :
                        $sformatf("ppn=0x%0h", req.pa)), UVM_MEDIUM)
        end
        else begin
          fail_cnt++;
          `uvm_error("LSU_CHK",
            $sformatf("FAIL %s va=0x%0h: no response", req.st_inst ? "ST" : "LD", va_map[i].va))
        end
      end
    end

    `uvm_info("LSU_CHK",
      $sformatf("LSU translate summary: %0d pass, %0d fail", pass_cnt, fail_cnt), UVM_LOW)
  endtask

endclass : mmu_lsu_translate_seq

`endif // MMU_LSU_TRANSLATE_SEQ_SV
