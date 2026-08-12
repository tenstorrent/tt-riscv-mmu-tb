// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
// address_space — SystemVerilog implementation.
//
// This is the address_space layer. It replaced an equivalent C++
// implementation, so the package name and function signature follow that
// original API.
//
// An "address space" here is simply a mem_manager instance (a chandle from
// mem_manager::create()). That matters because the testbench passes the handle
// straight into mem_manager::read_8()/write_8(), which require a real
// mem_manager* on the C side.
package address_space;

    typedef chandle address_space_t;

    // Memory-mapped device windows.
    //
    // NO-OP (kept for API compatibility). The C++ version dispatched accesses
    // inside a registered window to another mem_manager. Implementing that here
    // is not possible without also routing every access through SV: the
    // testbench calls mem_manager::read_8()/write_8() directly on the space
    // handle, so it would bypass any SV-side window lookup.
    //
    // This testbench never calls add_device (verified: no references under
    // sv/), so the windows are unused. If device dispatch is ever needed,
    // either route all accesses through a wrapper (see sv/common/mmu_sysmem.sv)
    // or go back to the C++ address_space.
    function automatic void add_device(chandle             as,
                                       mem_manager::addr_t addr,
                                       mem_manager::sz_t   size,
                                       chandle             device);
        // Intentionally empty. Warn once so a future user is not surprised.
        if (as == null) return;
        $warning("address_space::add_device is a no-op in the SV implementation (addr=0x%0h size=%0d)",
                 addr, size);
    endfunction

endpackage