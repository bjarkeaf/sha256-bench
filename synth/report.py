#!/usr/bin/env python3
"""
Parse Vivado OOC reports and emit one CSV row.

Usage:
    python synth/report.py <LOOP> <N_CORES> [PERIOD_NS] [PART]

Reads vivado_ooc_L<LOOP>_N<N_CORES>/util.rpt and timing.rpt.
Appends one line to results.csv (creates header if file is new).

CSV columns:
    loop, n_cores, part, target_period_ns,
    luts, ffs, wns_ns, achieved_fmax_mhz, throughput_gbps
"""

import sys
import re
import os
import csv

def parse_utilization(path):
    luts = ffs = None
    with open(path) as f:
        for line in f:
            # Match lines like: | Slice LUTs*             |   1234 |
            m = re.search(r'Slice LUTs\b[^|]*\|\s*(\d+)', line)
            if m:
                luts = int(m.group(1))
            m = re.search(r'Slice Registers\b[^|]*\|\s*(\d+)', line)
            if m:
                ffs = int(m.group(1))
    return luts, ffs

def parse_timing(path):
    wns = None
    with open(path) as f:
        for line in f:
            # Match: WNS(ns)     TNS(ns)  ...
            # then next data line
            if 'WNS' in line and 'TNS' in line:
                next(f, '')  # skip dashes line
                data = next(f, '').strip().split()
                if data:
                    try:
                        wns = float(data[0])
                    except ValueError:
                        pass
                break
    return wns

def main():
    if len(sys.argv) < 3:
        print("Usage: python report.py <LOOP> <N_CORES> [PERIOD_NS] [PART]")
        print("Example: python report.py 1 1")
        sys.exit(1)
    loop     = int(sys.argv[1])
    n_cores  = int(sys.argv[2])
    period   = float(sys.argv[3]) if len(sys.argv) > 3 else 2.5
    part     = sys.argv[4] if len(sys.argv) > 4 else "xc7z020clg400-1"

    outdir = f"vivado_ooc_L{loop}_N{n_cores}"
    util_path   = os.path.join(outdir, "util.rpt")
    timing_path = os.path.join(outdir, "timing.rpt")

    luts, ffs = parse_utilization(util_path)
    wns       = parse_timing(timing_path)

    if wns is not None:
        achieved_period = period - wns          # ns
        achieved_fmax   = 1000.0 / achieved_period  # MHz
    else:
        achieved_fmax = None

    throughput = (
        n_cores * 512 * achieved_fmax * 1e6 / loop / 1e9
        if achieved_fmax else None
    )

    fieldnames = [
        "loop", "n_cores", "part", "target_period_ns",
        "luts", "ffs", "wns_ns", "achieved_fmax_mhz", "throughput_gbps"
    ]

    csv_path = "results.csv"
    write_header = not os.path.exists(csv_path)

    with open(csv_path, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        if write_header:
            w.writeheader()
        w.writerow({
            "loop":              loop,
            "n_cores":           n_cores,
            "part":              part,
            "target_period_ns":  period,
            "luts":              luts,
            "ffs":               ffs,
            "wns_ns":            wns,
            "achieved_fmax_mhz": f"{achieved_fmax:.1f}" if achieved_fmax else "FAIL",
            "throughput_gbps":   f"{throughput:.2f}" if throughput else "FAIL",
        })

    print(f"L={loop} N={n_cores}: LUTs={luts} FFs={ffs} WNS={wns}ns "
          f"Fmax={achieved_fmax:.1f}MHz throughput={throughput:.2f}Gbps"
          if achieved_fmax else f"L={loop} N={n_cores}: route FAILED")

if __name__ == "__main__":
    main()
