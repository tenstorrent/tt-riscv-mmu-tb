#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
"""
pt_json_to_tb.py - convert a riescue riemap.py output.json into two flat
text files the SystemVerilog page-table loader reads with $fscanf.

Why: parsing JSON in pure SV is fragile. We parse in Python and emit simple
line-oriented files that SV can read trivially.

Outputs (written next to each other):
  <out>.entries : one PTE per line   "<addr_hex> <data_hex>"   (both 16 hex)
  <out>.cfg     : first line         "mode <sv39|...>"
                  second line        "satp_ppn <hex>"
                  then per mapped VA  "va <va_hex> <pa_hex> <size_kb>"

Internal PT-node pages (page-group ids starting with "map_") are skipped for
the VA list.

Usage:
  pt_json_to_tb.py <output.json> <out_prefix>
"""
import json
import sys


SIZE_TO_KB = {
    "4kb": 4, "2mb": 2 * 1024, "1gb": 1024 * 1024,
    "512gb": 512 * 1024 * 1024, "256tb": 256 * 1024 * 1024 * 1024,
}


def h(x):
    """Parse a hex string (possibly with 0x) or int into an int."""
    if isinstance(x, int):
        return x
    return int(x, 16)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: pt_json_to_tb.py <output.json> <out_prefix>")

    in_json, out_prefix = sys.argv[1], sys.argv[2]
    with open(in_json) as f:
        d = json.load(f)

    # ---- entries: PTE address -> value ----
    with open(out_prefix + ".entries", "w") as fe:
        for addr, data in d["entries"].items():
            fe.write(f"{h(addr):016x} {h(data):016x}\n")

    # ---- config: pick the first single-stage space ----
    spaces = d["spaces"]
    space = None
    for sp in spaces.values():
        if not sp.get("twostage", False):
            space = sp
            break
    if space is None:
        sys.exit("no single-stage space found in output.json")

    mode = space["paging_mode"]
    satp_ppn = h(space["top_base_addr"]) >> 12

    with open(out_prefix + ".cfg", "w") as fc:
        fc.write(f"mode {mode}\n")
        fc.write(f"satp_ppn {satp_ppn:x}\n")
        for pid, pages in space.get("pages", {}).items():
            if pid.startswith("map_"):
                continue  # internal PT-node pages, not stimulus
            for va, info in pages.items():
                pa = h(info["pa"])
                kb = SIZE_TO_KB.get(info.get("size", "4kb"), 4)
                fc.write(f"va {h(va):016x} {pa:016x} {kb}\n")


if __name__ == "__main__":
    main()
