//======================================================================
// filelist.f  -  compile order for the OpenC910 MMU plain-UVM testbench
//
// Usage (simulator-agnostic): pass with -f filelist.f
// Relative paths are resolved from the repository root (tt-riscv-mmu-tb/).
//======================================================================

//----------------------------------------------------------------------
// DUT: OpenC910 MMU RTL + boundary dependencies
//----------------------------------------------------------------------
+incdir+rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl
+incdir+rtl/openc910/C910_RTL_FACTORY/gen_rtl/cpu/rtl

// Global C910 configuration macros (PA_WIDTH, etc.) - must be first so the
// `define directives are visible to all MMU RTL that follows.
rtl/openc910/C910_RTL_FACTORY/gen_rtl/cpu/rtl/cpu_cfig.h

// MMU PMA "system map" region/attribute macros (SYSMAP_FLG*, etc.)
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/sysmap.h

// Shared cells used by the MMU
rtl/openc910/C910_RTL_FACTORY/gen_rtl/clk/rtl/gated_clk_cell.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/rtu/rtl/ct_rtu_compare_iid.v

// MMU single-port SRAM macros (wrappers) + their FPGA behavioural models
rtl/openc910/C910_RTL_FACTORY/gen_rtl/fpga/rtl/fpga_ram.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/fpga/rtl/ct_f_spsram_256x196.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/fpga/rtl/ct_f_spsram_256x84.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_spsram_256x196.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_spsram_256x84.v

// MMU leaf cells
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_iutlb_entry.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_iutlb_fst_entry.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_iplru.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_dutlb_entry.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_dutlb_huge_entry.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_dutlb_read.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_dplru.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_sysmap_hit.v

// MMU sub-blocks
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_iutlb.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_dutlb.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_jtlb_tag_array.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_jtlb_data_array.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_jtlb.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_ptw.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_arb.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_tlboper.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_regs.v
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_sysmap.v

// MMU top
rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl/ct_mmu_top.v

//----------------------------------------------------------------------
// Testbench (plain UVM)
//----------------------------------------------------------------------
+incdir+sv/intf
+incdir+sv/common
+incdir+sv/env
+incdir+sv/agents/ifu
+incdir+sv/agents/lsu
+incdir+sv/agents/csr
+incdir+sv/agents/ptwmem
+incdir+sv/agents/pmp
+incdir+sv/agents/tlb_inv
+incdir+sv/checkers
+incdir+sv/cfg
+incdir+sv/coverage
+incdir+sv/seq
+incdir+sv/tests

// Interfaces (outside any package)
sv/intf/mmu_if.sv
// Whitebox TLB backdoor interface (direct hierarchical reads; no DPI).
sv/intf/mmu_tlb_bd_if.sv

// Generated pysv DPI binding package for the in-sim riescue page-table
// generator (produced by `make ptgen`). Compiled before mmu_env_pkg, which
// imports it. The companion PageTableSV.o is linked into simv by the Makefile.
build/pysv_gen/PageTableSV_pkg.sv

// DPI memory packages (the DUT/TB physical memory).
// mem_manager is C++ (external/mem-manager submodule: storage, image loaders,
// sized read/write/check DPI); the sysmem / address_space layers are pure
// SystemVerilog (sv/sysmem) over that DPI.
// Order matters: mem_manager -> address_space -> sysmem. These must precede
// mmu_common_pkg below, which wraps them in mmu_sysmem.
// The C++ objects are compiled and linked by the Makefile.
external/mem-manager/src/mem_manager.svh
sv/sysmem/address_space.svh
sv/sysmem/sysmem.svh

// Package chain, compiled bottom-up:
//   common -> agent VIPs -> checkers -> env -> test
sv/common/mmu_common_pkg.sv
sv/agents/ifu/mmu_ifu_pkg.sv
sv/agents/lsu/mmu_lsu_pkg.sv
sv/agents/csr/mmu_csr_pkg.sv
sv/agents/ptwmem/mmu_ptwmem_pkg.sv
sv/agents/pmp/mmu_pmp_pkg.sv
sv/agents/tlb_inv/mmu_tlb_inv_pkg.sv
sv/coverage/mmu_coverage_pkg.sv
sv/checkers/mmu_checkers_pkg.sv
sv/env/mmu_env_pkg.sv
sv/tests/mmu_test_pkg.sv

// Testbench top
sv/tb/mmu_tb_top.sv
