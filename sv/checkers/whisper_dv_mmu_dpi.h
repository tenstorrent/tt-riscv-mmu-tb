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
 * Whisper DvMmu Model DPI Interface Header
 *
 * This header declares the DPI-C interface functions for the DvMmu
 * reference model. These functions are called from SystemVerilog via DPI-C.
 *
 */

#ifndef WHISPER_DV_MMU_DPI_H
#define WHISPER_DV_MMU_DPI_H

#ifdef __cplusplus
extern "C" {
#endif

// Create a new DvMmu model instance and return a handle
void* dv_mmu_new(unsigned long long mem_size);

// Destroy the DvMmu model instance
void dv_mmu_delete(void* handle);

// Perform address translation
// Returns: ExceptionCause value (0 = success/None)
// walk_complete (out): 1 if Whisper's most-recent walk reached a leaf PTE
// walk_pa       (out): Walk::result() PA. Valid when walk_complete=1, even
//                      if a downstream permission/A-D fault was raised.
// leaf_pte      (out): Raw leaf PTE value (Walk::ithPte(size()-1)) of the
//                      most-recent walk. Valid when walk_complete=1; reflects
//                      the post-A/D-writeback value. 0 when no walk occurred.
// vs_walk_complete (out): 1 if the VS-stage walk (walks[0], the first walk in two-stage translation) reached its leaf PTE.
int dv_mmu_translate(void* handle,
                     unsigned long long va_addr,
                     int priv_mode,
                     unsigned char two_stage,
                     unsigned char is_read,
                     unsigned char is_write,
                     unsigned char is_execute,
                     unsigned long long* gpa,
                     unsigned long long* pa,
                     unsigned char* walk_complete,
                     unsigned long long* walk_pa,
                     unsigned long long* leaf_pte,
                     unsigned char* vs_walk_complete);

// Configure stage1 translation (for VSATP changes)
void dv_mmu_config_stage1(void* handle,
                          int mode,
                          unsigned int asid,
                          unsigned long long ppn,
                          unsigned char sum);

// Configure stage2 translation (for HGATP changes)
void dv_mmu_config_stage2(void* handle,
                          int mode,
                          unsigned int asid,
                          unsigned long long ppn);

// Configure non-hypervisor translation (for SATP changes)
void dv_mmu_config_translation(void* handle,
                               int mode,
                               unsigned int asid,
                               unsigned long long ppn);

// Set fault on first access behavior
void dv_mmu_set_fault_on_first_access(void* handle, unsigned char flag);

// Set fault on first access for stage1
void dv_mmu_set_fault_on_first_access_stage1(void* handle, unsigned char flag);

// Set fault on first access for stage2
void dv_mmu_set_fault_on_first_access_stage2(void* handle, unsigned char flag);

// Enable/disable page-based memory types (Svpbmt)
void dv_mmu_enable_pbmt(void* handle, unsigned char flag);

// Enable/disable page-based memory types at VS stage
void dv_mmu_enable_vs_pbmt(void* handle, unsigned char flag);

// Enable/disable NAPOT page size (Svnapot - naturally aligned power of 2)
void dv_mmu_enable_napot(void* handle, unsigned char flag);

// Read from physical memory
// Returns: 1 = success, 0 = failure
unsigned char dv_mmu_mem_read(void* handle,
                              unsigned long long addr,
                              unsigned int size,
                              unsigned long long* data);

// Write to physical memory
// Returns: 1 = success, 0 = failure
unsigned char dv_mmu_mem_write(void* handle,
                               unsigned long long addr,
                               unsigned int size,
                               unsigned long long data);

// Read from memory-mapped register (PMP/PMA)
// Returns: 1 = success, 0 = failure
unsigned char dv_mmu_mmr_read(void* handle,
                              unsigned long long addr,
                              unsigned long long* data);

// Write to memory-mapped register (PMP/PMA)
// Returns: 1 = success, 0 = failure
unsigned char dv_mmu_mmr_write(void* handle,
                               unsigned long long addr,
                               unsigned long long* data);

// Define PMP registers
// Returns: 1 = success, 0 = failure
unsigned char dv_mmu_define_pmp_regs(void* handle,
                                     unsigned long long pmpcfg_addr,
                                     unsigned int pmpcfg_count,
                                     unsigned long long pmpaddr_addr,
                                     unsigned int pmpaddr_count);

// Define PMA registers: both the PMACFG window and the PMAMASK window.
// A count of 0 disables the corresponding window. Returns 1 = success, 0 = failure.
unsigned char dv_mmu_define_pma_regs(void* handle,
                                     unsigned long long pmacfg_addr,
                                     unsigned int pmacfg_count,
                                     unsigned long long pmamask_addr,
                                     unsigned int pmamask_count);

// Check if PMA is enabled
unsigned char dv_mmu_is_pma_enabled(void* handle);

// Cause of the continued GPA->SPA translation done after a VS-stage leaf fault.
int dv_mmu_get_final_stage_cause(void* handle);

// Check if PMP is enabled
unsigned char dv_mmu_is_pmp_enabled(void* handle);

// Check if address is PMP readable
unsigned char dv_mmu_is_pmp_readable(void* handle,
                                     unsigned long long addr,
                                     int priv_mode);

// Check if address is PMP writable
unsigned char dv_mmu_is_pmp_writable(void* handle,
                                     unsigned long long addr,
                                     int priv_mode);

// Check if address is PMA readable
unsigned char dv_mmu_is_pma_readable(void* handle, unsigned long long addr);

// Check if address is PMA writable
unsigned char dv_mmu_is_pma_writable(void* handle, unsigned long long addr);

// Get page size
unsigned int dv_mmu_get_page_size(void* handle);

// Get page number for address
unsigned int dv_mmu_get_page_number(void* handle, unsigned long long addr);

// Leaf PTE of the primary (index-0 / VS-stage) walk of the most-recent translate.
unsigned long long dv_mmu_get_vs_leaf_pte(void* handle);

#ifdef __cplusplus
}
#endif

#endif // WHISPER_DV_MMU_DPI_H

