// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
// sysmem — SystemVerilog implementation over the mem_manager DPI.
//
// This is the sysmem layer: named address spaces on top of the mem_manager DPI
// (external/mem-manager). It replaced an equivalent C++ implementation, so the
// package name and function signatures follow that original API.
//
// A named address space is just a mem_manager instance: get_address_space()
// hands back a chandle from mem_manager::create(). That is required because the
// testbench passes the handle straight into mem_manager::read_8()/write_8(),
// which need a real mem_manager* on the C side.
//
// Kept from the C++ version: the +plusarg bring-up in get().
//   +mem_init=%h            (see note below)
//   +load=<elf>             load_ELF into the "memory" space
//   +bootrom +bootrom_path= additionally load a bootrom ELF
//   +debug_rom_path= / +debugrom_path=  additionally load a debug ROM
//   +hex=<file>             load_verilog_hex instead
package sysmem;

    typedef chandle sysmem_t;

    // Registry of address spaces, keyed by name ("memory", ...). Each value is
    // a chandle wrapping a C++ mem_manager* returned by mem_manager::create().
    // Package-scope statics, so there is exactly one registry per simulation --
    // matching the C++ singleton behaviour.
    chandle address_space_by_name[string];
    bit     model_needs_init = 1'b1;

    // Look up an address space by name, creating its backing mem_manager on
    // first use. The returned chandle is a real C++ mem_manager*, which is what
    // makes it directly usable as the handle for mem_manager::read_8/write_8.
    function automatic chandle get_or_create_address_space(string name);
        if (!address_space_by_name.exists(name)) begin
            address_space_by_name[name] = mem_manager::create();
        end
        return address_space_by_name[name];
    endfunction

    // Lazily build the model and apply the image-loading plusargs.
    // Returns a handle used only as a token by get_address_space() below.
    function automatic chandle get();

        if (model_needs_init) begin

            integer init = 0;
            string  s, bootrom_path, debug_rom_path;
            chandle mem;

            // +mem_init: NO-OP here. The C++ sysmem passed this to the engine as
            // a fill pattern for freshly touched pages, but the mem_manager DPI
            // package exposes no init-pattern entry point, so there is nothing
            // to forward it to. Read (and ignored) so the plusarg stays legal.
            void'($value$plusargs("mem_init=%h", init));

            mem = get_or_create_address_space("memory");

            if ($value$plusargs("load=%s", s)) begin
                if ($test$plusargs("bootrom")) begin
                    $value$plusargs("bootrom_path=%s", bootrom_path);
                    mem_manager::load_ELF(mem, bootrom_path);
                end
                if ($value$plusargs("debug_rom_path=%s", debug_rom_path) ||
                    $value$plusargs("debugrom_path=%s", debug_rom_path)) begin
                    mem_manager::load_ELF(mem, debug_rom_path);
                end
                mem_manager::load_ELF(mem, s);
            end
            if ($value$plusargs("hex=%s", s)) begin
                mem_manager::load_verilog_hex(mem, s);
            end

            model_needs_init = 1'b0;

        end

        // The C++ version returned an opaque sysmem*; callers only ever feed it
        // back into get_address_space(), which ignores it here.
        return get_or_create_address_space("memory");

    endfunction

    // `l` is the token from get() and is unused: spaces are looked up by name.
    function automatic chandle get_address_space(chandle l, string name);
        return get_or_create_address_space(name);
    endfunction

    function automatic chandle create_address_space(chandle l, string name);
        return get_or_create_address_space(name);
    endfunction

    function automatic void destroy(chandle l);
        // Free every space we created. `l` is a token, not a container handle.
        foreach (address_space_by_name[n]) begin
            mem_manager::destroy(address_space_by_name[n]);
        end
        address_space_by_name.delete();
        model_needs_init = 1'b1;
    endfunction

    // NO-OP (API compatibility): there is no process-wide engine singleton to
    // tear down in this implementation.
    function automatic void sysmem_destroy_mem_mgr();
    endfunction

    // NO-OP (API compatibility): returns the SAME handle, not a copy.
    // The C++ sysmem deep-copied every space so a caller could snapshot memory
    // for reference-model lockstep; the mem_manager DPI package exposes no
    // clone entry point, so a true copy is not possible from SV. This testbench
    // never calls clone_mem (verified: no references under sv/).
    function automatic chandle clone_mem();
        $warning("sysmem::clone_mem is a no-op in the SV implementation - returning the original handle, NOT a copy");
        return get_or_create_address_space("memory");
    endfunction

    // NO-OP (API compatibility): the mem_manager DPI package exposes no
    // uninitialized-read randomization hook. Unused by this testbench.
    function automatic void address_space_randomize_uninitialized_read_data(
        chandle as, longint unsigned seed);
        $warning("sysmem::address_space_randomize_uninitialized_read_data is a no-op in the SV implementation (seed=%0d)", seed);
    endfunction

endpackage