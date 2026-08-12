#!/usr/bin/env python3
"""Codegen the pysv DPI bridge for PageTableSV.

Emits the C++ bridge (PageTableSV.cc) and the SystemVerilog binding package
(PageTableSV_pkg.sv) into the output dir. Codegen ONLY — no cmake build. The
.cc is compiled by the Makefile with the project's g++/libpython recipe (which
links the system shared libpython and the pysv-bundled pybind11).

Usage: python3 scripts/gen_pysv.py [out_dir]   (default: <repo>/build/pysv_gen)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # so `import PageTableSV` (this dir) resolves

from pysv import codegen, generate_sv_binding  # noqa: E402
# PageTableSV.py's build tail is guarded under `if __name__ == "__main__"`, so
# importing it here does NOT trigger a cmake build.
import PageTableSV as M  # noqa: E402

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "build", "pysv_gen")
os.makedirs(out, exist_ok=True)

with open(os.path.join(out, "PageTableSV.cc"), "w") as f:
    f.write(codegen.generate_pybind_code([M.PageTableSV]))
generate_sv_binding([M.PageTableSV], pkg_name="PageTableSV_pkg",
                    filename=os.path.join(out, "PageTableSV_pkg.sv"))

print("pysv codegen ->", os.path.abspath(out))
