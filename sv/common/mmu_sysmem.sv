// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
//======================================================================
// mmu_sysmem.sv
//
// DUT/TB physical memory, backed by the reused sysmem + mem-manager DPI engine
// (replaces an earlier lightweight in-SV memory model). It acquires the sysmem
// singleton's "memory" address space and exposes the same read_8 / write_8
// (little-endian, 64-bit) API the PTW responder and base sequence use, packing/
// unpacking the byte arrays mem_manager operates on.
//
// Uninitialized locations read as 0 (we do NOT call randomize), so the PTW
// walker correctly sees unwritten PTEs as invalid. ELF/hex program images can
// be loaded via sysmem's +load=/+hex= plusargs (mem_manager::load_ELF/hex).
//======================================================================

`ifndef MMU_SYSMEM_SV
`define MMU_SYSMEM_SV

class mmu_sysmem extends uvm_object;
  `uvm_object_utils(mmu_sysmem)

  // sysmem "memory" address space; doubles as the mem_manager handle (mm_t).
  chandle as;

  function new(string name = "mmu_sysmem");
    chandle sm;
    super.new(name);
    sm = sysmem::get();
    as = sysmem::get_address_space(sm, "memory");
    if (as == null)
      `uvm_fatal("MMU_SYSMEM", "sysmem 'memory' address space is null")
  endfunction

  // 8-byte little-endian write.
  function void write_8(longint unsigned addr, longint unsigned data);
    byte unsigned b[8];
    for (int i = 0; i < 8; i++) b[i] = data[8*i +: 8];
    mem_manager::write_8(as, addr, b);
  endfunction

  // 8-byte little-endian read (unwritten => 0).
  function longint unsigned read_8(longint unsigned addr);
    byte unsigned    b[8];
    byte unsigned    sts;
    longint unsigned data = '0;
    sts = mem_manager::read_8(as, addr, b);
    for (int i = 0; i < 8; i++) data[8*i +: 8] = b[i];
    return data;
  endfunction

endclass : mmu_sysmem

`endif // MMU_SYSMEM_SV
