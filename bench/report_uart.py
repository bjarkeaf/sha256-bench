#!/usr/bin/env python3
"""
Parsers for Vivado post-route reports produced by synth/uart.tcl.

Two entry points, both take absolute or relative paths to the report files:

    parse_utilization(rpt_path) -> {"lut": int, "ff": int, "bram_36k": float, "dsp": int}
    parse_timing(rpt_path)      -> {"wns_ns": float, "tns_ns": float}

Parsing style mirrors synth/report.py (line-by-line regex, no lxml/pandas).
Robust to Vivado 2019.x-2024.x variants of the summary table.
"""
import re


def parse_utilization(path):
    """Extract totals from a `report_utilization` .rpt file.

    Fields returned (missing values are None):
        lut       — "Slice LUTs" total (or "CLB LUTs" on UltraScale, but we
                    only care about 7-series here).
        ff        — "Slice Registers" total.
        bram_36k  — Block RAM in units of RAMB36 (RAMB18 counts as 0.5).
                    Comes from the "Block RAM Tile" row when present.
        dsp       — "DSPs" total (should always be 0 for SHA-256).
    """
    lut = ff = dsp = None
    bram_36k = 0.0
    bram_seen = False
    with open(path) as f:
        for line in f:
            if lut is None:
                m = re.search(r"Slice LUTs\b[^|]*\|\s*(\d+)", line)
                if m:
                    lut = int(m.group(1))
            if ff is None:
                m = re.search(r"Slice Registers\b[^|]*\|\s*(\d+)", line)
                if m:
                    ff = int(m.group(1))
            if dsp is None:
                m = re.search(r"DSPs\b[^|]*\|\s*(\d+)", line)
                if m:
                    dsp = int(m.group(1))
            # BRAM: prefer the "Block RAM Tile" summary line (in 36k units),
            # fall back to summing RAMB36 + RAMB18/2 rows.
            m = re.search(r"Block RAM Tile\b[^|]*\|\s*(\d+(?:\.\d+)?)", line)
            if m:
                bram_36k = float(m.group(1))
                bram_seen = True
            elif not bram_seen:
                m = re.search(r"RAMB36[^\|]*\|\s*(\d+)", line)
                if m:
                    bram_36k += float(m.group(1))
                m = re.search(r"RAMB18[^\|]*\|\s*(\d+)", line)
                if m:
                    bram_36k += float(m.group(1)) * 0.5
    return {"lut": lut, "ff": ff, "bram_36k": bram_36k, "dsp": dsp}


def parse_timing(path):
    """Extract WNS and TNS on the design's slowest clock from
    `report_timing_summary` output. Values are ns; positive means slack met."""
    wns = tns = None
    with open(path) as f:
        lines = list(f)

    # Find the "WNS(ns)  TNS(ns)  ..." header, then the first data row two
    # lines below (there's usually a `----------` separator between).
    for i, line in enumerate(lines):
        if "WNS(ns)" in line and "TNS(ns)" in line:
            # Skip the separator; grab the next line that has numeric data.
            for j in range(i + 1, min(i + 5, len(lines))):
                parts = lines[j].strip().split()
                if not parts:
                    continue
                try:
                    wns = float(parts[0])
                    tns = float(parts[1])
                    break
                except (ValueError, IndexError):
                    continue
            if wns is not None:
                break
    return {"wns_ns": wns, "tns_ns": tns}


if __name__ == "__main__":
    # Quick smoke-test entry point: `python3 bench/report_uart.py <util.rpt> <timing.rpt>`
    import json
    import sys
    if len(sys.argv) != 3:
        print("Usage: report_uart.py <util.rpt> <timing.rpt>", file=sys.stderr)
        sys.exit(2)
    print(json.dumps({
        "utilization": parse_utilization(sys.argv[1]),
        "timing":      parse_timing(sys.argv[2]),
    }, indent=2))
