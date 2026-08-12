// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
/*************************************************************************
 *
 * Tenstorrent CONFIDENTIAL
 *__________________
 *
 *  Tenstorrent Inc.
 *  All Rights Reserved.
 *
 * NOTICE:  All information contained herein is, and remains
 * the property of Tenstorrent Inc.  The intellectual
 * and technical concepts contained
 * herein are proprietary to Tenstorrent Inc.
 * and may be covered by U.S., Canadian and Foreign Patents,
 * patents in process, and are protected by trade secret or copyright law.
 * Dissemination of this information or reproduction of this material
 * is strictly forbidden unless prior written permission is obtained
 * from Tenstorrent Inc.
 *
 * Whisper DV MMU Model - DPI Wrapper for C++ DvMmu Reference Model
 *
 * This SystemVerilog model provides a UVM component wrapper for the
 * C++ DvMmu reference model library (libdvmmu.a) from dv-mmu.
 * It uses DPI-C to interface with the C++ library functions.
 *
 * To use this model:
 * 1. Ensure libdvmmu.a is linked during simulation compilation
 * 2. Instantiate this model in your testbench environment
 *
 */

`ifndef WHISPER_DV_MMU_SV
`define WHISPER_DV_MMU_SV

//======================================================================
// DPI-C function declarations (must be at package/module scope)
//======================================================================

// Create a new DvMmu model instance and return a handle
import "DPI-C" function chandle dv_mmu_new(input longint unsigned mem_size);

// Destroy the DvMmu model instance
import "DPI-C" function void dv_mmu_delete(input chandle handle);

// Perform address translation
// Returns: exception cause code (0 = success)
// walk_complete (out): 1 if Whisper's most-recent walk reached a leaf PTE
// walk_pa       (out): Walk::result() PA — valid when walk_complete=1, even
//                      if a permission/A-D fault was raised after the leaf
// leaf_pte      (out): Raw leaf PTE value — valid when walk_complete=1,
//                      reflects the post-A/D-writeback value; 0 if no walk
// vs_walk_complete (out): 1 if the primary walk walks[0] (the VS walk in two-stage, vs walk_complete=walks.back()) reached its leaf.
import "DPI-C" function int dv_mmu_translate(
  input chandle handle,
  input longint unsigned va_addr,
  input int priv_mode,
  input bit two_stage,
  input bit is_read,
  input bit is_write,
  input bit is_execute,
  output longint unsigned gpa,
  output longint unsigned pa,
  output byte unsigned walk_complete,
  output longint unsigned walk_pa,
  output longint unsigned leaf_pte,
  output byte unsigned vs_walk_complete
);

// Configure stage1 translation (for VSATP changes)
import "DPI-C" function void dv_mmu_config_stage1(
  input chandle handle,
  input int mode,
  input int unsigned asid,
  input longint unsigned ppn,
  input bit sum
);

// Configure stage2 translation (for HGATP changes)
import "DPI-C" function void dv_mmu_config_stage2(
  input chandle handle,
  input int mode,
  input int unsigned asid,
  input longint unsigned ppn
);

// Configure non-hypervisor translation (for SATP changes)
import "DPI-C" function void dv_mmu_config_translation(
  input chandle handle,
  input int mode,
  input int unsigned asid,
  input longint unsigned ppn
);

// Set fault on first access behavior
import "DPI-C" function void dv_mmu_set_fault_on_first_access(
  input chandle handle,
  input bit flag
);

// Set fault on first access for stage1
import "DPI-C" function void dv_mmu_set_fault_on_first_access_stage1(
  input chandle handle,
  input bit flag
);

// Set fault on first access for stage2
import "DPI-C" function void dv_mmu_set_fault_on_first_access_stage2(
  input chandle handle,
  input bit flag
);

// Enable/disable page-based memory types (Svpbmt)
import "DPI-C" function void dv_mmu_enable_pbmt(
  input chandle handle,
  input bit flag
);

// Enable/disable page-based memory types at VS stage
import "DPI-C" function void dv_mmu_enable_vs_pbmt(
  input chandle handle,
  input bit flag
);

// Enable/disable NAPOT page size (Svnapot - naturally aligned power of 2)
import "DPI-C" function void dv_mmu_enable_napot(
  input chandle handle,
  input bit flag
);

// Read from physical memory
import "DPI-C" function bit dv_mmu_mem_read(
  input chandle handle,
  input longint unsigned addr,
  input int unsigned size,
  output longint unsigned data
);

// Write to physical memory
import "DPI-C" function bit dv_mmu_mem_write(
  input chandle handle,
  input longint unsigned addr,
  input int unsigned size,
  input longint unsigned data
);

// Read from memory-mapped register (PMP/PMA)
import "DPI-C" function bit dv_mmu_mmr_read(
  input chandle handle,
  input longint unsigned addr,
  output longint unsigned data
);

// Write to memory-mapped register (PMP/PMA)
import "DPI-C" function bit dv_mmu_mmr_write(
  input chandle handle,
  input longint unsigned addr,
  inout longint unsigned data
);

// Define PMP registers
import "DPI-C" function bit dv_mmu_define_pmp_regs(
  input chandle handle,
  input longint unsigned pmpcfg_addr,
  input int unsigned pmpcfg_count,
  input longint unsigned pmpaddr_addr,
  input int unsigned pmpaddr_count
);

// Define PMA registers
import "DPI-C" function bit dv_mmu_define_pma_regs(
  input chandle handle,
  input longint unsigned pmacfg_addr,
  input int unsigned pmacfg_count,
  input longint unsigned pmamask_addr,
  input int unsigned pmamask_count
);

// Check if PMA is enabled
import "DPI-C" function bit dv_mmu_is_pma_enabled(input chandle handle);

// Cause of the continued GPA->SPA translation done after a VS-stage leaf fault.
import "DPI-C" function int dv_mmu_get_final_stage_cause(input chandle handle);

// Check if PMP is enabled
import "DPI-C" function bit dv_mmu_is_pmp_enabled(input chandle handle);

// Check if address is PMP readable
import "DPI-C" function bit dv_mmu_is_pmp_readable(
  input chandle handle,
  input longint unsigned addr,
  input int priv_mode
);

// Check if address is PMP writable
import "DPI-C" function bit dv_mmu_is_pmp_writable(
  input chandle handle,
  input longint unsigned addr,
  input int priv_mode
);

// Check if address is PMA readable
import "DPI-C" function bit dv_mmu_is_pma_readable(
  input chandle handle,
  input longint unsigned addr
);

// Check if address is PMA writable
import "DPI-C" function bit dv_mmu_is_pma_writable(
  input chandle handle,
  input longint unsigned addr
);

// Get page size
import "DPI-C" function int unsigned dv_mmu_get_page_size(input chandle handle);

// Get page number for address
import "DPI-C" function int unsigned dv_mmu_get_page_number(
  input chandle handle,
  input longint unsigned addr
);

// Leaf PTE of the primary (VS-stage) walk of the most-recent translate.
import "DPI-C" function longint unsigned dv_mmu_get_vs_leaf_pte(input chandle handle);

//==========================================================================
// Privilege Mode Enumeration (matches WdRiscv::PrivilegeMode)
//==========================================================================
typedef enum int {
  DV_MMU_PRIV_USER       = 0,
  DV_MMU_PRIV_SUPERVISOR = 1,
  DV_MMU_PRIV_RESERVED   = 2,
  DV_MMU_PRIV_MACHINE    = 3
} dv_mmu_privilege_mode_e;

//==========================================================================
// Translation Mode Enumeration (matches WdRiscv::VirtMem::Mode)
//==========================================================================
typedef enum int {
  DV_MMU_MODE_BARE  = 0,
  DV_MMU_MODE_SV32  = 1,
  DV_MMU_MODE_SV39  = 8,
  DV_MMU_MODE_SV48  = 9,
  DV_MMU_MODE_SV57  = 10
} dv_mmu_translation_mode_e;

//==========================================================================
// Exception Cause Enumeration (subset for MMU faults)
//==========================================================================
typedef enum int {
  DV_MMU_CAUSE_INST_ADDR_MISAL        = 0,  // Instruction address misaligned
  DV_MMU_CAUSE_INST_ACC_FAULT         = 1,  // Instruction access fault
  DV_MMU_CAUSE_ILLEGAL_INST           = 2,  // Illegal instruction
  DV_MMU_CAUSE_BREAKP                 = 3,  // Breakpoint
  DV_MMU_CAUSE_LOAD_ADDR_MISAL        = 4,  // Load address misaligned
  DV_MMU_CAUSE_LOAD_ACC_FAULT         = 5,  // Load access fault
  DV_MMU_CAUSE_STORE_ADDR_MISAL       = 6,  // Store address misaligned
  DV_MMU_CAUSE_STORE_ACC_FAULT        = 7,  // Store access fault.
  DV_MMU_CAUSE_U_ENV_CALL             = 8,  // Environment call from user mode
  DV_MMU_CAUSE_S_ENV_CALL             = 9,  // Environment call from supervisor mode
  DV_MMU_CAUSE_VS_ENV_CALL            = 10, // Environment call from virtual supervisor mode
  DV_MMU_CAUSE_M_ENV_CALL             = 11, // Environment call from machine mode
  DV_MMU_CAUSE_INST_PAGE_FAULT        = 12, // Instruction page fault
  DV_MMU_CAUSE_LOAD_PAGE_FAULT        = 13, // Load page fault
  DV_MMU_CAUSE_STORE_PAGE_FAULT       = 15, // Store page fault
  DV_MMU_CAUSE_DOUBLE_TRAP            = 16,
  DV_MMU_CAUSE_RESERVED0              = 17,
  DV_MMU_CAUSE_SOFTWARE_CHECK         = 18,
  DV_MMU_CAUSE_HARDWARE_ERROR         = 19,
  DV_MMU_CAUSE_INST_GUEST_PAGE_FAULT  = 20, // Instruction guest-page fault.
  DV_MMU_CAUSE_LOAD_GUEST_PAGE_FAULT  = 21, // Load guest-page fault.
  DV_MMU_CAUSE_VIRT_INST              = 22, // Virtual instruction
  DV_MMU_CAUSE_STORE_GUEST_PAGE_FAULT = 23, // Store guest-page fault.
  DV_MMU_CAUSE_NONE                   = 24

} dv_mmu_exception_cause_e;

//==========================================================================
// whisper_dv_mmu UVM Component Class
//==========================================================================
class whisper_dv_mmu extends uvm_component;

  `uvm_component_utils(whisper_dv_mmu)

  // Handle to the C++ DvMmu model instance
  chandle mmu_handle;

  // Configuration parameters
  int unsigned instance_id;
  bit enabled;
  // Model memory bound (bytes); set by the env before connect_phase. DvMmu
  // treats pa >= mem_size as out-of-bounds, so this must cover the PA range.
  longint unsigned mem_size = 64'h1_0000_0000;  // default 4 GB

  // Statistics
  int unsigned num_translations;
  int unsigned num_page_faults;
  int unsigned num_guest_page_faults;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    mmu_handle = null;
    instance_id = 0;
    enabled = 1;
    num_translations = 0;
    num_page_faults = 0;
    num_guest_page_faults = 0;
  endfunction : new

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    `uvm_info(get_name(), "Building whisper_dv_mmu", UVM_MEDIUM)
  endfunction : build_phase

  //==========================================================================
  // UVM Component Methods
  //==========================================================================

  // Create and initialize the C++ DvMmu model instance
  virtual function void create_mmu_instance(longint unsigned mem_size = 64'h100000000);
    if (mmu_handle == null) begin
      mmu_handle = dv_mmu_new(mem_size);
      if (mmu_handle == null) begin
        `uvm_error(get_name(), "Failed to create DvMmu model instance")
      end else begin
        // `uvm_info(get_name(), $sformatf("Created DvMmu model instance (mem_size=0x%0x)", mem_size), UVM_MEDIUM)
      end
    end else begin
      // `uvm_warning(get_name(), "DvMmu model instance already exists")
    end
  endfunction : create_mmu_instance

  // Destroy the C++ DvMmu model instance
  virtual function void destroy_mmu_instance();
    if (mmu_handle != null) begin
      dv_mmu_delete(mmu_handle);
      mmu_handle = null;
      `uvm_info(get_name(), "Destroyed DvMmu model instance", UVM_MEDIUM)
    end
  endfunction : destroy_mmu_instance

  // Perform address translation
  // Returns: 1 = success, 0 = fault
  virtual function bit translate(
    input longint unsigned va_addr,
    input dv_mmu_privilege_mode_e priv_mode,
    input bit two_stage,
    input bit is_read,
    input bit is_write,
    input bit is_execute,
    output longint unsigned gpa,
    output longint unsigned pa,
    output dv_mmu_exception_cause_e fault_cause,
    output bit walk_complete,
    output longint unsigned walk_pa,
    output longint unsigned leaf_pte,
    output bit vs_walk_complete
  );
    int result;
    byte unsigned walk_complete_byte;
    byte unsigned vs_walk_complete_byte;

    if (mmu_handle == null || !enabled) begin
      // `uvm_warning(get_name(), "Translation requested but DvMmu model not available or disabled")
      walk_complete = 1'b0;
      walk_pa = '0;
      leaf_pte = '0;
      vs_walk_complete = 1'b0;
      return 0;
    end
    // `uvm_info(get_name(), $sformatf("Translating VA: 0x%0x, priv_mode=%0d, two_stage=%0d, is_read=%0d, is_write=%0d, is_execute=%0d", va_addr, priv_mode, two_stage, is_read, is_write, is_execute), UVM_DEBUG)
    result = dv_mmu_translate(mmu_handle, va_addr, int'(priv_mode), two_stage,
                               is_read, is_write, is_execute, gpa, pa,
                               walk_complete_byte, walk_pa, leaf_pte,
                               vs_walk_complete_byte);
    walk_complete = (walk_complete_byte != 8'h0);
    vs_walk_complete = (vs_walk_complete_byte != 8'h0);

    fault_cause = dv_mmu_exception_cause_e'(result);
    num_translations++;

    if (result != DV_MMU_CAUSE_NONE) begin
      if (result >= 20 && result <= 23)
        num_guest_page_faults++;
      else
        num_page_faults++;

      `uvm_info(get_name(),
        $sformatf("Translation fault: VA=0x%0x, cause=%0d (%s)",
                  va_addr, result, fault_cause.name()), UVM_DEBUG)
      return 0;
    end else begin
      `uvm_info(get_name(),
        $sformatf("Translation success: VA=0x%0x -> GPA=0x%0x -> PA=0x%0x",
                  va_addr, gpa, pa), UVM_DEBUG)
      return 1;
    end
  endfunction : translate

  // NOTE: the reference wrapper had a map_whisper_cause_to_flt_type() helper that
  // returned dv/mmu's Core_pkg::MmuFltType_e. That taxonomy is dv/mmu-specific and
  // not present in this repo, so the helper is dropped here — the C910 scoreboard
  // classifies faults against the DUT's own fault signals (mmu_ifu_pgflt / deny).

  // Cause of Whisper's continued GPA->SPA translation after a VS-stage leaf fault
  // (DV_MMU_CAUSE_NONE if that step did not run).
  virtual function dv_mmu_exception_cause_e get_final_stage_cause();
    if (mmu_handle != null && enabled)
      return dv_mmu_exception_cause_e'(dv_mmu_get_final_stage_cause(mmu_handle));
    else
      return DV_MMU_CAUSE_NONE;
  endfunction : get_final_stage_cause

  // Configure stage1 translation (VSATP)
  virtual function void config_stage1(
    input dv_mmu_translation_mode_e mode,
    input int unsigned asid,
    input longint unsigned ppn,
    input bit sum
  );
    if (mmu_handle != null && enabled) begin
      dv_mmu_config_stage1(mmu_handle, int'(mode), asid, ppn, sum);
      // `uvm_info(get_name(),
      //   $sformatf("Configured stage1: mode=%s, asid=%0d, ppn=0x%0x, sum=%0d",
      //             mode.name(), asid, ppn, sum), UVM_DEBUG)
    end else begin
      // `uvm_warning(get_name(), "Cannot configure stage1: DvMmu model not available or disabled")
    end
  endfunction : config_stage1

  // Configure stage2 translation (HGATP)
  virtual function void config_stage2(
    input dv_mmu_translation_mode_e mode,
    input int unsigned asid,
    input longint unsigned ppn
  );
    if (mmu_handle != null && enabled) begin
      dv_mmu_config_stage2(mmu_handle, int'(mode), asid, ppn);
      `uvm_info(get_name(),
        $sformatf("Configured stage2: mode=%s, asid=%0d, ppn=0x%0x",
                  mode.name(), asid, ppn), UVM_DEBUG)
    end else begin
      `uvm_warning(get_name(), "Cannot configure stage2: DvMmu model not available or disabled")
    end
  endfunction : config_stage2

  // Configure non-hypervisor translation (SATP)
  virtual function void config_translation(
    input dv_mmu_translation_mode_e mode,
    input int unsigned asid,
    input longint unsigned ppn
  );
    if (mmu_handle != null && enabled) begin
      dv_mmu_config_translation(mmu_handle, int'(mode), asid, ppn);
      // `uvm_info(get_name(),
      //   $sformatf("Configured translation: mode=%s, asid=%0d, ppn=0x%0x",
      //             mode.name(), asid, ppn), UVM_DEBUG)
    end else begin
      // `uvm_warning(get_name(), "Cannot configure translation: DvMmu model not available or disabled")
    end
  endfunction : config_translation

  // Set fault on first access behavior
  virtual function void set_fault_on_first_access(bit flag, int stage = 0);
    if (mmu_handle != null && enabled) begin
      case (stage)
        0: dv_mmu_set_fault_on_first_access(mmu_handle, flag);
        1: dv_mmu_set_fault_on_first_access_stage1(mmu_handle, flag);
        2: dv_mmu_set_fault_on_first_access_stage2(mmu_handle, flag);
        default: dv_mmu_set_fault_on_first_access(mmu_handle, flag);
      endcase
      `uvm_info(get_name(),
        $sformatf("Set fault_on_first_access=%0d for stage %0d", flag, stage), UVM_DEBUG)
    end else begin
      `uvm_warning(get_name(), "Cannot set fault_on_first_access: DvMmu model not available or disabled")
    end
  endfunction : set_fault_on_first_access

  // Enable/disable page-based memory types (Svpbmt extension)
  virtual function void enable_pbmt(bit flag);
    if (mmu_handle != null && enabled) begin
      dv_mmu_enable_pbmt(mmu_handle, flag);
      // `uvm_info(get_name(),
      //   $sformatf("PBMT (Svpbmt) %s", flag ? "enabled" : "disabled"), UVM_DEBUG)
    end else begin
      // `uvm_warning(get_name(), "Cannot set enable_pbmt: DvMmu model not available or disabled")
    end
  endfunction : enable_pbmt

  // Enable/disable page-based memory types at VS stage
  virtual function void enable_vs_pbmt(bit flag);
    if (mmu_handle != null && enabled) begin
      dv_mmu_enable_vs_pbmt(mmu_handle, flag);
      `uvm_info(get_name(),
        $sformatf("VS-stage PBMT %s", flag ? "enabled" : "disabled"), UVM_DEBUG)
    end else begin
      `uvm_warning(get_name(), "Cannot set enable_vs_pbmt: DvMmu model not available or disabled")
    end
  endfunction : enable_vs_pbmt

  // Enable/disable NAPOT page size (Svnapot extension - naturally aligned power of 2)
  virtual function void enable_napot(bit flag);
    if (mmu_handle != null && enabled) begin
      dv_mmu_enable_napot(mmu_handle, flag);
      // `uvm_info(get_name(),
      //   $sformatf("NAPOT (Svnapot) %s", flag ? "enabled" : "disabled"), UVM_DEBUG)
    end else begin
      // `uvm_warning(get_name(), "Cannot set enable_napot: DvMmu model not available or disabled")
    end
  endfunction : enable_napot

  // Read from physical memory
  virtual function bit mem_read(
    input longint unsigned addr,
    input int unsigned size,
    output longint unsigned data
  );
    bit result;

    if (mmu_handle == null || !enabled) begin
      `uvm_warning(get_name(), "Memory read requested but DvMmu model not available or disabled")
      return 0;
    end

    result = dv_mmu_mem_read(mmu_handle, addr, size, data);

    if (result) begin
      //`uvm_info(get_name(),
      //  $sformatf("Memory read: addr=0x%0x, size=%0d, data=0x%0x", addr, size, data), UVM_DEBUG)
    end else begin
      `uvm_info(get_name(),
        $sformatf("Memory read failed: addr=0x%0x, size=%0d", addr, size), UVM_DEBUG)
    end

    return result;
  endfunction : mem_read

  // Write to physical memory
  virtual function bit mem_write(
    input longint unsigned addr,
    input int unsigned size,
    input longint unsigned data
  );
    bit result;

    if (mmu_handle == null || !enabled) begin
      // `uvm_warning(get_name(), "Memory write requested but DvMmu model not available or disabled")
      return 0;
    end

    result = dv_mmu_mem_write(mmu_handle, addr, size, data);

    if (result) begin
      // `uvm_info(get_name(),
      //   $sformatf("Memory write: addr=0x%0x, size=%0d, data=0x%0x", addr, size, data), UVM_DEBUG)
    end else begin
      // `uvm_info(get_name(),
      //   $sformatf("Memory write failed: addr=0x%0x, size=%0d", addr, size), UVM_DEBUG)
    end

    return result;
  endfunction : mem_write

  // Read from memory-mapped register (PMP/PMA)
  virtual function bit mmr_read(
    input longint unsigned addr,
    output longint unsigned data
  );
    if (mmu_handle != null && enabled) begin
      return dv_mmu_mmr_read(mmu_handle, addr, data);
    end
    return 0;
  endfunction : mmr_read

  // Write to memory-mapped register (PMP/PMA)
  virtual function bit mmr_write(
    input longint unsigned addr,
    inout longint unsigned data
  );
    if (mmu_handle != null && enabled) begin
      return dv_mmu_mmr_write(mmu_handle, addr, data);
    end
    return 0;
  endfunction : mmr_write

  // Define PMP registers
  virtual function bit define_pmp_regs(
    input longint unsigned pmpcfg_addr,
    input int unsigned pmpcfg_count,
    input longint unsigned pmpaddr_addr,
    input int unsigned pmpaddr_count
  );
    if (mmu_handle != null) begin
      bit result = dv_mmu_define_pmp_regs(mmu_handle, pmpcfg_addr, pmpcfg_count,
                                           pmpaddr_addr, pmpaddr_count);
      if (result) begin
        `uvm_info(get_name(),
          $sformatf("Defined PMP regs: pmpcfg_addr=0x%0x, count=%0d, pmpaddr_addr=0x%0x, count=%0d",
                    pmpcfg_addr, pmpcfg_count, pmpaddr_addr, pmpaddr_count), UVM_MEDIUM)
      end else begin
        `uvm_error(get_name(), "Failed to define PMP registers")
      end
      return result;
    end
    return 0;
  endfunction : define_pmp_regs

  // Define PMA registers (PMACFG + PMAMASK windows)
  virtual function bit define_pma_regs(
    input longint unsigned pmacfg_addr,
    input int unsigned pmacfg_count,
    input longint unsigned pmamask_addr,
    input int unsigned pmamask_count
  );
    if (mmu_handle != null) begin
      bit result = dv_mmu_define_pma_regs(mmu_handle, pmacfg_addr, pmacfg_count,
                                          pmamask_addr, pmamask_count);
      if (!result) begin
        `uvm_error(get_name(), "Failed to define PMA/PMAMASK registers")
      end
      return result;
    end
    return 0;
  endfunction : define_pma_regs

  // Check if PMA is enabled
  virtual function bit is_pma_enabled();
    if (mmu_handle != null) begin
      return dv_mmu_is_pma_enabled(mmu_handle);
    end
    return 0;
  endfunction : is_pma_enabled

  // Check if PMP is enabled
  virtual function bit is_pmp_enabled();
    if (mmu_handle != null) begin
      return dv_mmu_is_pmp_enabled(mmu_handle);
    end
    return 0;
  endfunction : is_pmp_enabled

  // Check PMP readability
  virtual function bit is_pmp_readable(
    input longint unsigned addr,
    input dv_mmu_privilege_mode_e priv_mode
  );
    if (mmu_handle != null) begin
      return dv_mmu_is_pmp_readable(mmu_handle, addr, int'(priv_mode));
    end
    return 0; // Default to not readable if no handle
  endfunction : is_pmp_readable

  // Check PMP writability
  virtual function bit is_pmp_writable(
    input longint unsigned addr,
    input dv_mmu_privilege_mode_e priv_mode
  );
    if (mmu_handle != null) begin
      return dv_mmu_is_pmp_writable(mmu_handle, addr, int'(priv_mode));
    end
    return 0; // Default to not writable if no handle
  endfunction : is_pmp_writable

  // Check PMA readability
  virtual function bit is_pma_readable(input longint unsigned addr);
    if (mmu_handle != null) begin
      return dv_mmu_is_pma_readable(mmu_handle, addr);
    end
    return 0; // Default to not readable if no handle
  endfunction : is_pma_readable

  // Check PMA writability
  virtual function bit is_pma_writable(input longint unsigned addr);
    if (mmu_handle != null) begin
      return dv_mmu_is_pma_writable(mmu_handle, addr);
    end
    return 0; // Default to not writable if no handle
  endfunction : is_pma_writable

  // Get page size
  virtual function int unsigned get_page_size();
    if (mmu_handle != null) begin
      return dv_mmu_get_page_size(mmu_handle);
    end
    return 4096; // Default 4KB page
  endfunction : get_page_size

  // Get page number for address
  virtual function int unsigned get_page_number(input longint unsigned addr);
    if (mmu_handle != null) begin
      return dv_mmu_get_page_number(mmu_handle, addr);
    end
    return addr >> 12; // Default 4KB page
  endfunction : get_page_number

  // Leaf PTE of the primary (VS-stage) walk of the most-recent translate. The
  // translate() leaf_pte output is walks.back() (= G-leaf in two-stage); this
  // returns walks[0]'s leaf for VS-stage perm classification. Call immediately
  // after translate() (reads last-translation walk state).
  virtual function longint unsigned get_vs_leaf_pte();
    if (mmu_handle != null) begin
      return dv_mmu_get_vs_leaf_pte(mmu_handle);
    end
    return 0;
  endfunction : get_vs_leaf_pte

  // Set instance ID
  virtual function void set_instance_id(input int id);
    instance_id = id;
  endfunction : set_instance_id

  // Enable/disable the model
  virtual function void set_enabled(input bit en);
    enabled = en;
    `uvm_info(get_name(), $sformatf("DvMmu model %0s", en ? "enabled" : "disabled"), UVM_MEDIUM)
  endfunction : set_enabled

  // Print statistics
  virtual function void print_stats();
    // `uvm_info(get_name(),
    //   $sformatf("DvMmu Stats - Translations: %0d, Page Faults: %0d, Guest Page Faults: %0d",
    //             num_translations, num_page_faults, num_guest_page_faults), UVM_MEDIUM)
  endfunction : print_stats

  //==========================================================================
  // UVM Phase Methods
  //==========================================================================

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    // Create MMU instance after all connections are made
    create_mmu_instance(mem_size);
  endfunction : connect_phase

  virtual function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
    `uvm_info(get_name(), "Whisper DvMmu model end of elaboration", UVM_MEDIUM)
  endfunction : end_of_elaboration_phase

  virtual task run_phase(uvm_phase phase);
    super.run_phase(phase);
    // Model is ready for use
  endtask : run_phase

  virtual function void extract_phase(uvm_phase phase);
    super.extract_phase(phase);
    print_stats();
  endfunction : extract_phase

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    // `uvm_info(get_name(),
    //   $sformatf("Whisper DvMmu Model Report - Instance ID: %0d, Enabled: %0d",
    //             instance_id, enabled), UVM_MEDIUM)
  endfunction : report_phase

  virtual function void final_phase(uvm_phase phase);
    super.final_phase(phase);
    // Clean up C++ instance
    destroy_mmu_instance();
  endfunction : final_phase

endclass : whisper_dv_mmu

`endif // WHISPER_DV_MMU_SV
