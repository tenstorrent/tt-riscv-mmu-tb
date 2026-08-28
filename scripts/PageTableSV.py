#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.

import sys
from pathlib import Path
# Plain open-source pysv (no Bazel pysv_wrapper shim).
from pysv import sv, compile_lib, generate_sv_binding, DataType


def _ensure_riemap_path():
    """Make riescue's riemap page-table generator importable.

    Module-level (NOT a class method) so pysv can resolve it from the @sv
    methods that reference it — pysv imports helper symbols as module globals.

    Non-Bazel: riescue is vendored at external/riescue in this repo.
    Resolution order:
      1. already importable;
      2. $RIESCUE_ROOT (if set);
      3. external/riescue relative to this file (../../external/riescue);
      4. any 'riescue' dir already on sys.path.
    """
    import os
    import sys
    from pathlib import Path

    def _add(repo_root):
        repo_root = Path(repo_root)
        if not (repo_root / "riescue" / "riemap").is_dir():
            return False
        if str(repo_root) not in sys.path:
            sys.path.append(str(repo_root))
        return True

    try:
        from riescue.riemap import json_frontend  # noqa: F401
        return
    except ImportError:
        pass

    # 2) explicit override
    env_root = os.environ.get("RIESCUE_ROOT")
    if env_root and _add(env_root):
        return

    # 3) vendored submodule: scripts/PageTableSV.py -> ../external/riescue
    here = Path(__file__).resolve()
    if _add(here.parent.parent / "external" / "riescue"):
        return

    # 4) anything named 'riescue' already on the path
    for p in list(sys.path):
        if "riescue" in p and _add(Path(p)):
            return


class PageTableSV:
    """Python class to generate and parse page tables"""

    @sv()
    def __init__(self):
        """Initialize the PageTableSV class"""
        self.pte_entries = []
        self.space_va_list = {}  # space_id -> [va1, va2, ...] for batch method
        self.space_is_virtual = {}  # space_id -> is_virtual flag for batch method

        # Single-stage space fields (SATP)
        self.has_single_stage_space = False
        self.satp_base_addr = 0
        self.satp_ppn = 0
        self.satp_paging_mode = ""

        # 2-stage space fields (VSATP + HGATP)
        self.has_two_stage_space = False
        self.vsatp_base_addr = 0
        self.vsatp_ppn = 0
        self.vsatp_paging_mode = ""
        self.hgatp_base_addr = 0
        self.hgatp_ppn = 0
        self.hgatp_paging_mode = ""

        # Legacy fields for backwards compatibility
        self.paging_mode = ""
        self.gstage_paging_mode = ""
        self.gstage_base_addr = 0
        self.gstage_ppn = 0
        self.two_stage_enabled = False

    @sv(json_file=DataType.String, seed=DataType.Int, return_type=DataType.Int)
    def generate_page_tables_from_json(self, json_file, seed):
        """
        Generate page tables from a JSON configuration file using the riemap library.

        Args:
            json_file: Path to the JSON configuration file
            seed: Random seed for reproducibility

        Returns:
            Number of PTE entries generated, or -1 on error
        """
        _ensure_riemap_path()
        from riescue.riemap import json_frontend as riemap
        try:
            config = riemap.PageTableConfig.from_json_file(Path(json_file))
            output = riemap.generate_page_tables(config, seed=seed)

            # Dump output JSON to current working directory (run path)
            import os
            output_path = Path(os.getcwd()) / "generated_pt_output.json"
            output.to_json_file(output_path)
            print(f"INFO: Dumped generated page table output to {output_path}")

            # Use all spaces
            self._populate_from_output(output, list(output.spaces.keys()))

            return len(self.pte_entries)

        except Exception as e:
            print(f"ERROR in generate_page_tables_from_json: {e}")
            import traceback
            traceback.print_exc()
            return -1

    @sv(config_json=DataType.String, seed=DataType.Int, switch_num=DataType.Int, sim_time=DataType.LongInt, debug_log=DataType.Int, return_type=DataType.Int)
    def generate_page_tables_from_config_str(self, config_json, seed, switch_num=0, sim_time=0, debug_log=0):
        """
        Generate page tables from a JSON configuration string.
        Used for dynamic SATP switching where config is generated at runtime.

        Args:
            config_json: JSON string containing the configuration
            seed: Random seed for reproducibility
            switch_num: SATP switch number (for debug logging)
            sim_time: Simulation time in ns (for debug logging)

        Returns:
            Number of PTE entries generated, or -1 on error
        """
        import json
        _ensure_riemap_path()
        from riescue.riemap import json_frontend as riemap

        try:
            config_dict = json.loads(config_json)
            config = riemap.PageTableConfig.from_dict(config_dict)
            output = riemap.generate_page_tables(config, seed=seed)

            # Dump output JSON to current working directory
            # For dynamic SATP switches, create separate files per switch; otherwise use default name
            import os
            if switch_num > 0:
                output_path = Path(os.getcwd()) / f"generated_pt_output_switch_{switch_num}.json"
            else:
                output_path = Path(os.getcwd()) / "generated_pt_output.json"
            output.to_json_file(output_path)
            print(f"INFO: Dumped generated page table output to {output_path}")
            
            # Also update the default file with latest output for backward compatibility
            if switch_num > 0:
                default_path = Path(os.getcwd()) / "generated_pt_output.json"
                output.to_json_file(default_path)
                print(f"INFO: Updated default output file: {default_path}")

            # Use all spaces
            self._populate_from_output(output, list(output.spaces.keys()))



            return len(self.pte_entries)

        except Exception as e:
            print(f"ERROR in generate_page_tables_from_config_str: {e}")
            import traceback
            traceback.print_exc()
            return -1

    @sv(output_json_file=DataType.String, space_id=DataType.String, return_type=DataType.Int)
    def load_page_tables_from_output(self, output_json_file, space_id):
        """
        Load page tables from a pre-generated output.json file.

        Args:
            output_json_file: Path to the output.json file (generated by riemap)
            space_id: Which space to load (e.g., "space1", "space2"). Use empty string for all spaces.

        Returns:
            Number of PTE entries loaded, or -1 on error
        """
        _ensure_riemap_path()
        from riescue.riemap import json_frontend as riemap
        try:
            output = riemap.PageTableOutput.from_json_file(Path(output_json_file))

            # Use provided space_id or all spaces if empty
            if space_id:
                self._populate_from_output(output, [space_id])
            else:
                self._populate_from_output(output, list(output.spaces.keys()))

            return len(self.pte_entries)

        except Exception as e:
            print(f"ERROR in load_page_tables_from_output: {e}")
            import traceback
            traceback.print_exc()
            return -1

    def _populate_from_output(self, output, space_ids: list):
        """
        Populate internal data structures from PageTableOutput.

        Handles mixed mode where one space is 2-stage and another is single-stage.
        VAs are tagged with is_virtual based on their source space's translation type.

        Args:
            output: PageTableOutput from generate_page_tables
            space_ids: List of space IDs to extract data from
        """
        self.pte_entries = []

        # Reset space tracking
        self.has_single_stage_space = False
        self.has_two_stage_space = False
        self.satp_base_addr = 0
        self.satp_ppn = 0
        self.satp_paging_mode = ""
        self.vsatp_base_addr = 0
        self.vsatp_ppn = 0
        self.vsatp_paging_mode = ""
        self.hgatp_base_addr = 0
        self.hgatp_ppn = 0
        self.hgatp_paging_mode = ""

        # First pass: identify single-stage and 2-stage spaces using twostage property
        single_stage_spaces = []
        two_stage_spaces = []

        for space_id in space_ids:
            space = output.spaces[space_id]
            if not hasattr(space, 'twostage'):
                raise ValueError(f"ERROR: Space '{space_id}' missing required 'twostage' property in JSON output")
            space_is_twostage = space.twostage

            if space_is_twostage:
                two_stage_spaces.append(space_id)
            else:
                single_stage_spaces.append(space_id)

        # Process single-stage space (use first one if multiple - per constraint, should be at most one)
        if single_stage_spaces:
            self.has_single_stage_space = True
            space_id = single_stage_spaces[0]
            space = output.spaces[space_id]
            self.satp_paging_mode = space.paging_mode.upper()
            self.satp_base_addr = space.top_base_addr or 0
            self.satp_ppn = self.satp_base_addr >> 12
            print(f"INFO: Single-stage space '{space_id}': mode={self.satp_paging_mode}, SATP base=0x{self.satp_base_addr:x}")

        # Process 2-stage space (use first one if multiple - per constraint, should be at most one)
        if two_stage_spaces:
            self.has_two_stage_space = True
            space_id = two_stage_spaces[0]
            space = output.spaces[space_id]
            # Handle None paging modes (when stage is disabled)
            self.vsatp_paging_mode = space.paging_mode.upper() if space.paging_mode else "DISABLE"
            self.vsatp_base_addr = space.top_base_addr or 0
            self.vsatp_ppn = self.vsatp_base_addr >> 12
            self.hgatp_paging_mode = space.gstage_paging_mode.upper() if space.gstage_paging_mode else "DISABLE"
            self.hgatp_base_addr = space.gstage_top_base_addr or 0
            self.hgatp_ppn = self.hgatp_base_addr >> 12
            print(f"INFO: 2-stage space '{space_id}': VS-stage={self.vsatp_paging_mode}, G-stage={self.hgatp_paging_mode}")
            print(f"INFO: VSATP base=0x{self.vsatp_base_addr:x}, HGATP base=0x{self.hgatp_base_addr:x}")

        # Set legacy fields for backwards compatibility
        if self.has_two_stage_space:
            self.paging_mode = self.vsatp_paging_mode
            self.gstage_paging_mode = self.hgatp_paging_mode
            self.gstage_base_addr = self.hgatp_base_addr
            self.gstage_ppn = self.hgatp_ppn
            self.two_stage_enabled = True
        elif self.has_single_stage_space:
            self.paging_mode = self.satp_paging_mode
            self.two_stage_enabled = False

        # Build unique PTE entries from output.entries (for sysmem population)
        # output.entries contains all PTE addr -> value pairs (no duplicates)
        for pte_addr, pte_value in output.entries.items():
            self.pte_entries.append({
                'level': -1,  # Level not needed for sysmem writes
                'pte_addr': pte_addr,
                'pte_data': pte_value,
            })

        # Build VA list and VA->PA mapping from all specified spaces
        # Tag each VA with is_virtual based on its source space's twostage property
        for space_id in space_ids:
            space = output.spaces[space_id]
            if not hasattr(space, 'twostage'):
                raise ValueError(f"ERROR: Space '{space_id}' missing required 'twostage' property in JSON output")
            space_is_two_stage = space.twostage

            # Initialize per-space tracking for batch methods
            self.space_va_list[space_id] = []
            self.space_is_virtual[space_id] = space_is_two_stage

            for page_id, va_map in space.pages.items():
                # Skip internal pages like map_os_sptbr_lin
                if page_id.startswith("map_"):
                    continue
                for va, page_entry in va_map.items():
                    self.space_va_list[space_id].append(va)

        # Print summary using new batch structures
        total_vas = sum(len(vas) for vas in self.space_va_list.values())
        num_virtual = sum(len(vas) for sid, vas in self.space_va_list.items() if self.space_is_virtual[sid])
        print("INFO: Loaded " + str(len(self.pte_entries)) + " PTEs, " + str(total_vas) + " VAs (" + str(num_virtual) + " virtual, " + str(total_vas - num_virtual) + " non-virtual)")

    @sv(return_type=DataType.Int)
    def get_num_vas(self):
        """Get the total number of virtual addresses across all spaces"""
        return sum(len(vas) for vas in self.space_va_list.values())
    
    @sv(return_type=DataType.LongInt)
    def get_satp_ppn(self):
        """Get the SATP PPN"""
        return self.satp_ppn
    
    @sv(return_type=DataType.String)
    def get_paging_mode(self):
        """Get the paging mode"""
        if not self.paging_mode:
            raise ValueError("paging_mode not set - page table not loaded")
        return self.paging_mode

    @sv(return_type=DataType.String)
    def get_gstage_paging_mode(self):
        """Get the G-stage paging mode for 2-stage translation"""
        if not self.gstage_paging_mode:
            raise ValueError("gstage_paging_mode not set - 2-stage translation not configured")
        return self.gstage_paging_mode

    @sv(return_type=DataType.LongInt)
    def get_gstage_base_addr(self):
        """Get the G-stage (HGATP) base address"""
        return self.gstage_base_addr

    @sv(return_type=DataType.Int)
    def is_two_stage_enabled(self):
        if self.two_stage_enabled:
            return 1
        return 0

    @sv(return_type=DataType.Int)
    def has_single_stage(self):
        if self.has_single_stage_space:
            return 1
        return 0

    @sv(return_type=DataType.Int)
    def has_two_stage(self):
        if self.has_two_stage_space:
            return 1
        return 0

    @sv(return_type=DataType.String)
    def get_satp_paging_mode(self):
        if self.satp_paging_mode:
            return self.satp_paging_mode
        return "NONE"

    @sv(return_type=DataType.String)
    def get_vsatp_paging_mode(self):
        if self.vsatp_paging_mode:
            return self.vsatp_paging_mode
        return "NONE"

    @sv(return_type=DataType.String)
    def get_hgatp_paging_mode(self):
        if self.hgatp_paging_mode:
            return self.hgatp_paging_mode
        return "NONE"

    @sv(return_type=DataType.LongInt)
    def get_vsatp_ppn(self):
        """Get the VSATP PPN for 2-stage space"""
        return self.vsatp_ppn

    @sv(return_type=DataType.LongInt)
    def get_hgatp_ppn(self):
        """Get the HGATP PPN for 2-stage space"""
        return self.hgatp_ppn

    @sv(batch_idx=DataType.Int, batch_size=DataType.Int, return_type=DataType.String)
    def get_vas_batch(self, batch_idx, batch_size):
        """Get batch of VAs as string: 'va:is_virtual,va:is_virtual,...'
        
        Args:
            batch_idx: Batch index (0, 1, 2, ...)
            batch_size: Number of entries per batch (e.g., 500)
        
        Returns comma-separated entries. Empty string when no more data.
        """
        all_vas = []
        for space_id in self.space_va_list:
            va_list = self.space_va_list[space_id]
            is_virt = self.space_is_virtual[space_id]
            virt_val = 1 if is_virt else 0
            for va in va_list:
                all_vas.append((va, virt_val))
        
        start = batch_idx * batch_size
        end = start + batch_size
        if start >= len(all_vas):
            return ""
        
        batch = all_vas[start:end]
        parts = []
        for va, virt_val in batch:
            parts.append(format(va, 'x') + ":" + str(virt_val))
        return ",".join(parts)

    @sv(batch_idx=DataType.Int, batch_size=DataType.Int, return_type=DataType.String)
    def get_ptes_batch(self, batch_idx, batch_size):
        """Get batch of PTEs as string: 'addr:data,addr:data,...'
        
        Args:
            batch_idx: Batch index (0, 1, 2, ...)
            batch_size: Number of entries per batch (e.g., 500)
        
        Returns comma-separated entries. Empty string when no more data.
        """
        start = batch_idx * batch_size
        end = start + batch_size
        if start >= len(self.pte_entries):
            return ""
        
        batch = self.pte_entries[start:end]
        parts = []
        for entry in batch:
            pte_addr = entry['pte_addr']
            pte_data = entry['pte_data']
            parts.append(format(pte_addr, 'x') + ":" + format(pte_data, 'x'))
        return ",".join(parts)

    @sv(json_file_path=DataType.String, return_type=DataType.String)
    def read_json_file_content(self, json_file_path):
        """
        Read the content of a JSON file and return it as a string.
        
        Args:
            json_file_path: Path to the JSON file to read
            
        Returns:
            String containing the JSON file content, or empty string if file doesn't exist
        """
        try:
            json_path = Path(json_file_path)
            if json_path.exists():
                with open(json_path, 'r') as f:
                    return f.read()
            else:
                return ""
        except Exception as e:
            print(f"ERROR: Failed to read JSON file {json_file_path}: {e}")
            return ""

# Codegen/build ONLY when this script is run directly (e.g.
# `python3 scripts/PageTableSV.py`) — NEVER on import. The sim's embedded
# interpreter imports this module at runtime to obtain the class definition,
# and must not re-trigger a cmake build (which would fail / is unwanted).
if __name__ == "__main__":
    # Compile the code into a shared library for DPI to load (inside ./build)
    # and generate the SV binding package.
    lib_path = compile_lib([PageTableSV], cwd="build")
    generate_sv_binding([PageTableSV], filename="PageTableSV_pkg.sv",
        pkg_name="PageTableSV_pkg")

