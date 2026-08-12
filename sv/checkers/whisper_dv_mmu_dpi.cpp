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
 * Whisper DvMmu Model DPI Interface
 *
 * This file provides the DPI-C interface between SystemVerilog and the
 * C++ DvMmu reference model library (libdvmmu.a).
 *
 * The functions in this file are called from SystemVerilog via DPI-C
 * and delegate to the actual C++ DvMmu model implementation.
 *
 */

#include "svdpi.h"
#include "whisper_dv_mmu_dpi.h"
#include "DvMmu.hpp"

#include <stdint.h>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <exception>
#include <string>

using namespace TT_DV_MMU;

// ----------------------------------------------------------------------------
// Debug-log helpers for the human-readable whisper.log page-walk dump.
// ----------------------------------------------------------------------------
namespace {

// Decode WdRiscv::ExceptionCause to its enum name (NONE=24 means no fault).
const char* causeName(int c) {
    switch (c) {
        case 0:  return "INST_ADDR_MISAL";
        case 1:  return "INST_ACC_FAULT";
        case 2:  return "ILLEGAL_INST";
        case 3:  return "BREAKP";
        case 4:  return "LOAD_ADDR_MISAL";
        case 5:  return "LOAD_ACC_FAULT";
        case 6:  return "STORE_ADDR_MISAL";
        case 7:  return "STORE_ACC_FAULT";
        case 8:  return "U_ENV_CALL";
        case 9:  return "S_ENV_CALL";
        case 10: return "VS_ENV_CALL";
        case 11: return "M_ENV_CALL";
        case 12: return "INST_PAGE_FAULT";
        case 13: return "LOAD_PAGE_FAULT";
        case 15: return "STORE_PAGE_FAULT";
        case 16: return "DOUBLE_TRAP";
        case 18: return "SOFTWARE_CHECK";
        case 19: return "HARDWARE_ERROR";
        case 20: return "INST_GUEST_PAGE_FAULT";
        case 21: return "LOAD_GUEST_PAGE_FAULT";
        case 22: return "VIRT_INST";
        case 23: return "STORE_GUEST_PAGE_FAULT";
        case 24: return "NONE";
        default: return "UNKNOWN";
    }
}

}  // namespace

//==========================================================================
// DPI-C Interface Functions
//==========================================================================
// These functions are called from SystemVerilog and must match the
// DPI declarations in whisper_dv_mmu.sv
//==========================================================================

extern "C" {

// Create a new DvMmu model instance and return a handle
void* dv_mmu_new(unsigned long long mem_size) {
    DvMmu* mmu = new DvMmu(static_cast<uint64_t>(mem_size));
    return reinterpret_cast<void*>(mmu);
}

// Destroy the DvMmu model instance
void dv_mmu_delete(void* handle) {
    if (handle != nullptr) {
        DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
        delete mmu;
    }
}

// Perform address translation
// Returns: ExceptionCause value (0 = success/None)
//
// walk_complete (out): 1 if Whisper's most-recent walk reached a leaf PTE
//   (Walk::complete()). Distinguishes structural walk failures
//   (walk_complete=0) from leaf-reached cases (walk_complete=1, which may
//   still have a downstream permission/A-D fault).
// walk_pa (out): The PA Whisper produced from the walk (Walk::result()). On
//   the newer Whisper this is populated at leaf detection — so it is valid
//   even when the walk faulted on a permission/A-D check after the leaf.
//   Zero if the walk did not reach a leaf.
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
                     unsigned char* vs_walk_complete) {
    if (handle == nullptr) {
        return -1; // Invalid handle
    }

    DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);

    WdRiscv::PrivilegeMode pm = static_cast<WdRiscv::PrivilegeMode>(priv_mode);
    bool twoStage = (two_stage != 0);
    bool read = (is_read != 0);
    bool write = (is_write != 0);
    bool exec = (is_execute != 0);

    uint64_t gpaOut = 0;
    uint64_t paOut = 0;

    WdRiscv::ExceptionCause cause = mmu->translate(static_cast<uint64_t>(va_addr), pm,
                                                    twoStage, read, write, exec,
                                                    gpaOut, paOut);

    *gpa = static_cast<unsigned long long>(gpaOut);
    *pa = static_cast<unsigned long long>(paOut);

    // Report walk outcome from the most-recent walk in the relevant vector.
    const auto& walks = mmu->getPageTableWalks();
    if (walks.empty()) {
        *walk_complete = 0;
        *walk_pa = 0;
        *leaf_pte = 0;
        *vs_walk_complete = 0;
    } else {
        const auto& w = walks.back();
        *walk_complete = w.complete() ? 1 : 0;
        *walk_pa = static_cast<unsigned long long>(w.result());
        *leaf_pte = (w.size() > 0)
                        ? static_cast<unsigned long long>(w.ithPte(w.size() - 1))
                        : 0;
        // Primary (index-0) walk's leaf completion — the VS walk in two-stage.
        *vs_walk_complete = walks[0].complete() ? 1 : 0;
    }

    // ==== BEGIN WHISPER_WALK_DEBUG ====
    // Human-readable, structured dump of the (possibly two-stage) page-table
    // walk. Each G-stage sub-walk is nested under the VS-stage PTE whose GPA it
    // resolves, so the GVA->GPA->SPA relationship is visible. The exception
    // cause is decoded to a name; the walk that carries the fault is marked.
    {
        static std::ofstream whisper_log("whisper.log");
        std::ostream& wlog = whisper_log;

        const char* privStr = (priv_mode == 0) ? "U-mode"
                            : (priv_mode == 1) ? "S-mode"
                            : (priv_mode == 3) ? "M-mode" : "?-mode";
        const char* accStr  = exec ? "FETCH" : (write ? "STORE" : "LOAD");
        const int    noneC   = int(WdRiscv::ExceptionCause::NONE);
        const int    causeI  = int(cause);
        const bool   faulted = (causeI != noneC);
        const size_t nW      = walks.size();

        // Locate the walk that carries the overall fault (its cause matches the
        // translate cause) so its leaf line can be marked.
        size_t faultWalkIdx = nW;  // nW == "none"
        if (faulted)
            for (size_t wi = 0; wi < nW; ++wi)
                if (int(walks[wi].exceptionCause()) == causeI)
                    faultWalkIdx = wi;  // keep last (deepest) match

        wlog << "================================================================\n";
        wlog << "TRANSLATE  VA=0x" << std::hex << va_addr << std::dec
             << "   [" << privStr << ", " << accStr << ", "
             << (twoStage ? "2-stage" : "1-stage") << "]\n";
        if (faulted)
            wlog << "  OUTCOME: FAULT  " << causeName(causeI) << "(" << causeI << ")\n";
        else
            wlog << "  OUTCOME: OK\n";
        wlog << "           gpa=0x" << std::hex << gpaOut
             << "  pa=0x" << paOut << std::dec
             << "  walk_complete=" << int(*walk_complete)
             << "  walk_pa=0x" << std::hex << (unsigned long long)(*walk_pa) << std::dec
             << "  walks=" << nW << "\n";
        wlog << "----------------------------------------------------------------\n";

        // Print one PTE/level line with all decoded bits; mark the faulting leaf.
        auto lvlLine = [&](const char* indent, int level, const char* tag,
                           uint64_t addr, uint64_t pte, bool markFault) {
            int leaf = (((pte >> 1) | (pte >> 2) | (pte >> 3)) & 1);
            wlog << indent << "L" << level << " " << tag << "=0x" << std::hex << addr
                 << " PTE=0x" << pte << std::dec
                 << " (V=" << ((pte >> 0) & 1)
                 << " R=" << ((pte >> 1) & 1)
                 << " W=" << ((pte >> 2) & 1)
                 << " X=" << ((pte >> 3) & 1)
                 << " U=" << ((pte >> 4) & 1)
                 << " G=" << ((pte >> 5) & 1)
                 << " A=" << ((pte >> 6) & 1)
                 << " D=" << ((pte >> 7) & 1)
                 << " N=" << ((pte >> 63) & 1)
                 << " PBMT=" << ((pte >> 61) & 3)
                 << " leaf=" << leaf << ")";
            if (markFault) wlog << "   <== FAULT";
            wlog << "\n";
        };

        // Print every level of one walk at a fixed indent.
        auto printLevels = [&](const char* indent, size_t wIdx, const char* tag) {
            const auto& w = walks[wIdx];
            int maxLvl = int(w.maxLevels());
            for (size_t i = 0; i < w.size(); ++i) {
                int level   = maxLvl - 1 - int(i);
                bool isLast = (i + 1 == w.size());
                bool mf     = (faulted && wIdx == faultWalkIdx && isLast);
                lvlLine(indent, level, tag, w.ithPteAddr(i), w.ithPte(i), mf);
            }
        };

        bool haveVs = (nW > 0 && walks[0].isStage1());
        if (twoStage && haveVs) {
            const auto& vs = walks[0];
            wlog << "  VS-stage  GVA=0x" << std::hex << va_addr
                 << " -> GPA=0x" << vs.result() << std::dec << "\n";
            int maxLvl = int(vs.maxLevels());
            for (size_t i = 0; i < vs.size(); ++i) {
                int level     = maxLvl - 1 - int(i);
                uint64_t addr = vs.ithPteAddr(i);
                bool isLast   = (i + 1 == vs.size());
                bool mf       = (faulted && faultWalkIdx == 0 && isLast);
                lvlLine("    ", level, "gpa", addr, vs.ithPte(i), mf);
                // Child G-stage walk that resolves this VS PTE's GPA -> SPA.
                for (size_t g = 1; g < nW; ++g) {
                    if (walks[g].isStage2() && walks[g].start() == addr) {
                        wlog << "      +- G-walk (PTE gpa->spa) -> spa=0x"
                             << std::hex << walks[g].result() << std::dec;
                        int gc = int(walks[g].exceptionCause());
                        if (gc != noneC) wlog << "  [" << causeName(gc) << "]";
                        wlog << "\n";
                        printLevels("          ", g, "spa");
                        break;
                    }
                }
            }
            // Final GPA -> SPA translation of the VS-stage leaf output.
            bool foundFinal = false;
            for (size_t g = 1; g < nW; ++g) {
                if (walks[g].isStage2() && walks[g].start() == vs.result()) {
                    wlog << "    final GPA->SPA -> spa=0x"
                         << std::hex << walks[g].result() << std::dec;
                    int gc = int(walks[g].exceptionCause());
                    if (gc != noneC) wlog << "  [" << causeName(gc) << "]";
                    wlog << "\n";
                    printLevels("        ", g, "spa");
                    foundFinal = true;
                    break;
                }
            }
            if (!foundFinal && int(vs.exceptionCause()) != noneC)
                wlog << "    final GPA->SPA: SKIPPED (faulted at VS-stage)\n";
        } else {
            const char* stg = (nW > 0 && walks[0].isStage2()) ? "G-stage" : "S-stage";
            wlog << "  " << stg << "  VA=0x" << std::hex << va_addr
                 << " -> PA=0x" << paOut << std::dec << "\n";
            for (size_t wi = 0; wi < nW; ++wi)
                printLevels("    ", wi, "pa");
            if (nW == 0) wlog << "    (no walk recorded)\n";
        }
        wlog << "================================================================\n";
    }
    // ==== END WHISPER_WALK_DEBUG ====

    return static_cast<int>(cause);
}

// Configure stage1 translation (for VSATP changes)
void dv_mmu_config_stage1(void* handle,
                          int mode,
                          unsigned int asid,
                          unsigned long long ppn,
                          unsigned char sum) {
    if (handle != nullptr) {
        DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
        WdRiscv::VirtMem::Mode modeEnum = static_cast<WdRiscv::VirtMem::Mode>(mode);
        mmu->configStage1(modeEnum, asid, static_cast<uint64_t>(ppn), sum != 0);
    }
}

// Configure stage2 translation (for HGATP changes)
void dv_mmu_config_stage2(void* handle,
                          int mode,
                          unsigned int asid,
                          unsigned long long ppn) {
    if (handle != nullptr) {
        DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
        WdRiscv::VirtMem::Mode modeEnum = static_cast<WdRiscv::VirtMem::Mode>(mode);
        mmu->configStage2(modeEnum, asid, static_cast<uint64_t>(ppn));
    }
}

// Configure non-hypervisor translation (for SATP changes)
void dv_mmu_config_translation(void* handle,
                               int mode,
                               unsigned int asid,
                               unsigned long long ppn) {
    if (handle != nullptr) {
        DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
        WdRiscv::VirtMem::Mode modeEnum = static_cast<WdRiscv::VirtMem::Mode>(mode);
        mmu->configTranslation(modeEnum, asid, static_cast<uint64_t>(ppn));
    }
}

// Set fault on first access behavior
void dv_mmu_set_fault_on_first_access(void* handle, unsigned char flag) {
    if (handle != nullptr) {
        DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
        mmu->setFaultOnFirstAccess(flag != 0);
    }
}

// Set fault on first access for stage1
void dv_mmu_set_fault_on_first_access_stage1(void* handle, unsigned char flag) {
    if (handle != nullptr) {
        DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
        mmu->setFaultOnFirstAccessStage1(flag != 0);
    }
}

// Set fault on first access for stage2
void dv_mmu_set_fault_on_first_access_stage2(void* handle, unsigned char flag) {
    if (handle != nullptr) {
        DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
        mmu->setFaultOnFirstAccessStage2(flag != 0);
    }
}

// Enable/disable page-based memory types (Svpbmt)
void dv_mmu_enable_pbmt(void* handle, unsigned char flag) {
    if (handle != nullptr) {
        DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
        mmu->enablePbmt(flag != 0);
    }
}

// Enable/disable page-based memory types at VS stage
void dv_mmu_enable_vs_pbmt(void* handle, unsigned char flag) {
    if (handle != nullptr) {
        DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
        mmu->enableVsPbmt(flag != 0);
    }
}

// Enable/disable NAPOT page size (Svnapot - naturally aligned power of 2)
void dv_mmu_enable_napot(void* handle, unsigned char flag) {
    if (handle != nullptr) {
        DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
        mmu->enableNapot(flag != 0);
    }
}

// Read from physical memory
// Returns: 1 = success, 0 = failure
unsigned char dv_mmu_mem_read(void* handle,
                              unsigned long long addr,
                              unsigned int size,
                              unsigned long long* data) {
    if (handle == nullptr) {
        return 0;
    }
    
    DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
    uint64_t dataOut = 0;
    
    bool result = mmu->memRead(static_cast<uint64_t>(addr), size, dataOut);
    *data = static_cast<unsigned long long>(dataOut);
    
    return result ? 1 : 0;
}

// Write to physical memory
// Returns: 1 = success, 0 = failure
unsigned char dv_mmu_mem_write(void* handle,
                               unsigned long long addr,
                               unsigned int size,
                               unsigned long long data) {
    if (handle == nullptr) {
        return 0;
    }
    
    DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
    bool result = mmu->memWrite(static_cast<uint64_t>(addr), size, static_cast<uint64_t>(data));
    
    return result ? 1 : 0;
}

// Read from memory-mapped register (PMP/PMA)
// Returns: 1 = success, 0 = failure
unsigned char dv_mmu_mmr_read(void* handle,
                              unsigned long long addr,
                              unsigned long long* data) {
    if (handle == nullptr) {
        *data = 0;
        return 0;
    }

    try {
        DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
        uint64_t dataOut = 0;

        bool result = mmu->mmrRead(static_cast<uint64_t>(addr), dataOut);
        *data = static_cast<unsigned long long>(dataOut);

        return result ? 1 : 0;
    } catch (const std::exception&) {
        *data = 0;
        return 0;
    } catch (...) {
        *data = 0;
        return 0;
    }
}

// Write to memory-mapped register (PMP/PMA)
// Returns: 1 = success, 0 = failure
unsigned char dv_mmu_mmr_write(void* handle,
                               unsigned long long addr,
                               unsigned long long* data) {
    if (handle == nullptr) {
        return 0;
    }

    try {
        DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);

        // Convert to uint64_t for C++ API (mmrWrite expects uint64_t& reference)
        uint64_t dataVal = static_cast<uint64_t>(*data);

        // Call mmrWrite - it will modify dataVal to the legalized value
        bool result = mmu->mmrWrite(static_cast<uint64_t>(addr), dataVal);

        // Return legalized value back to SystemVerilog
        *data = static_cast<unsigned long long>(dataVal);

        return result ? 1 : 0;
    } catch (const std::exception&) {
        return 0;
    } catch (...) {
        return 0;
    }
}

// Define PMP registers
// Returns: 1 = success, 0 = failure
unsigned char dv_mmu_define_pmp_regs(void* handle,
                                     unsigned long long pmpcfg_addr,
                                     unsigned int pmpcfg_count,
                                     unsigned long long pmpaddr_addr,
                                     unsigned int pmpaddr_count) {
    if (handle == nullptr) {
        return 0;
    }

    DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
    bool result = mmu->definePmpRegs(static_cast<uint64_t>(pmpcfg_addr), pmpcfg_count,
                                      static_cast<uint64_t>(pmpaddr_addr), pmpaddr_count);

    return result ? 1 : 0;
}

// Define PMA registers
// Returns: 1 = success, 0 = failure
unsigned char dv_mmu_define_pma_regs(void* handle,
                                     unsigned long long pmacfg_addr,
                                     unsigned int pmacfg_count,
                                     unsigned long long pmamask_addr,
                                     unsigned int pmamask_count) {
    if (handle == nullptr)
        return 0;
    DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
    bool result = mmu->definePmaRegs(static_cast<uint64_t>(pmacfg_addr), pmacfg_count,
                                     static_cast<uint64_t>(pmamask_addr), pmamask_count);
    return result ? 1 : 0;
}

// Check if PMA is enabled
unsigned char dv_mmu_is_pma_enabled(void* handle) {
    if (handle == nullptr) {
        return 0;
    }
    
    DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
    return mmu->isPmaEnabled() ? 1 : 0;
}

// Cause of the continued GPA->SPA translation done after a VS-stage leaf fault
// (DV_MMU_CAUSE_NONE if that step did not run).
int dv_mmu_get_final_stage_cause(void* handle) {
    if (handle == nullptr) {
        return static_cast<int>(WdRiscv::ExceptionCause::NONE);
    }
    DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
    return mmu->lastFinalStageCause();
}

// Check if PMP is enabled
unsigned char dv_mmu_is_pmp_enabled(void* handle) {
    if (handle == nullptr) {
        return 0;
    }
    
    DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
    return mmu->isPmpEnabled() ? 1 : 0;
}

// Check if address is PMP readable
unsigned char dv_mmu_is_pmp_readable(void* handle,
                                     unsigned long long addr,
                                     int priv_mode) {
    if (handle == nullptr) {
        return 1; // Default to readable if no handle
    }

    DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
    WdRiscv::PrivilegeMode pm = static_cast<WdRiscv::PrivilegeMode>(priv_mode);
    bool result = mmu->isPmpReadable(static_cast<uint64_t>(addr), pm);
    return result ? 1 : 0;
}

// Check if address is PMP writable
unsigned char dv_mmu_is_pmp_writable(void* handle,
                                     unsigned long long addr,
                                     int priv_mode) {
    if (handle == nullptr) {
        return 1; // Default to writable if no handle
    }

    DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
    WdRiscv::PrivilegeMode pm = static_cast<WdRiscv::PrivilegeMode>(priv_mode);
    bool result = mmu->isPmpWritable(static_cast<uint64_t>(addr), pm);
    return result ? 1 : 0;
}

// Check if address is PMA readable
unsigned char dv_mmu_is_pma_readable(void* handle, unsigned long long addr) {
    if (handle == nullptr) {
        return 1; // Default to readable if no handle
    }

    DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
    bool result = mmu->isPmaReadable(static_cast<uint64_t>(addr));
    return result ? 1 : 0;
}

// Check if address is PMA writable
unsigned char dv_mmu_is_pma_writable(void* handle, unsigned long long addr) {
    if (handle == nullptr) {
        return 1; // Default to writable if no handle
    }

    DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
    bool result = mmu->isPmaWritable(static_cast<uint64_t>(addr));
    return result ? 1 : 0;
}

// Get page size
unsigned int dv_mmu_get_page_size(void* handle) {
    if (handle == nullptr) {
        return 4096; // Default 4KB page
    }
    
    DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
    return mmu->pageSize();
}

// Get page number for address
unsigned int dv_mmu_get_page_number(void* handle, unsigned long long addr) {
    if (handle == nullptr) {
        return static_cast<unsigned int>(addr >> 12); // Default 4KB page
    }

    DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
    return mmu->pageNumber(static_cast<uint64_t>(addr));
}

// Leaf PTE of the primary (index-0) walk from the most-recent translate — the
// VS-stage leaf in two-stage (vs the G-stage leaf returned via translate's
// leaf_pte = walks.back()). 0 if no walk was recorded.
unsigned long long dv_mmu_get_vs_leaf_pte(void* handle) {
    if (handle == nullptr)
        return 0;
    DvMmu* mmu = reinterpret_cast<DvMmu*>(handle);
    const auto& walks = mmu->getPageTableWalks();
    if (walks.empty())
        return 0;
    const auto& w = walks[0];
    return (w.size() > 0)
               ? static_cast<unsigned long long>(w.ithPte(w.size() - 1))
               : 0ULL;
}

} // extern "C"

