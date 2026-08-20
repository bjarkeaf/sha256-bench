#!/usr/bin/env python3
"""
Overnight hardware sweep for sha256_stream_{uart,bscan}_top on Pynq-Z2.

Two readback modes (choose one):

  UART mode (requires a USB-UART adapter on PMOD JA1):
    python3 bench/hw_sweep.py --port /dev/ttyUSB1
    python3 bench/hw_sweep.py --port COM6 --rebuild   # Windows

  BSCAN mode (single USB cable, no adapter needed):
    python3 bench/hw_sweep.py --bscan
    python3 bench/hw_sweep.py --bscan --loops 1,2,4

For each LOOP the script:
  1. Builds the bitstream (synth/uart.tcl or synth/bscan.tcl) if needed.
  2. Parses post-route util.rpt + timing.rpt for area and timing.
  3. Programs the FPGA and reads back STREAM+ROOT lines (UART: over serial;
     BSCAN: via scan_dr_hw_jtag inside bench/program_bscan.tcl).
  4. Computes the Python golden (sim/ref_stream.py) and diffs.
  5. Appends one row to results_hw_sweep.csv.

Dependencies:
    Vivado on PATH.
    UART mode only: pip install pyserial
"""
import argparse
import csv
import datetime
import os
import re
import subprocess
import sys
import time
from pathlib import Path

try:
    import serial  # pyserial — only required for UART mode
    _SERIAL_AVAILABLE = True
except ImportError:
    _SERIAL_AVAILABLE = False

# The plan's canonical LOOP set (divisors of 64).
LEGAL_LOOPS = [1, 2, 4, 8, 16, 32, 64]

# Repo layout (paths resolved relative to the repo root, which we cd into).
REPO_ROOT     = Path(__file__).resolve().parent.parent
UART_TCL      = REPO_ROOT / "synth" / "uart.tcl"
BSCAN_TCL     = REPO_ROOT / "synth" / "bscan.tcl"
PROG_TCL      = REPO_ROOT / "bench" / "program.tcl"
PROG_BSCAN_TCL = REPO_ROOT / "bench" / "program_bscan.tcl"
REF_PY        = REPO_ROOT / "sim"   / "ref_stream.py"
CSV_PATH      = REPO_ROOT / "results_hw_sweep.csv"

sys.path.insert(0, str(REPO_ROOT / "bench"))
from report_uart import parse_utilization, parse_timing, parse_block_breakdown  # noqa: E402


def vivado(*args):
    """Return a subprocess command list for Vivado, handling Windows .bat."""
    cmd = ["vivado"] + list(args)
    if sys.platform == "win32":
        cmd = ["cmd.exe", "/c"] + cmd
    return cmd


# ---------------------------------------------------------------------------
# Provenance helpers
# ---------------------------------------------------------------------------
def get_git_sha():
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=REPO_ROOT, capture_output=True, text=True, timeout=5,
        )
        return r.stdout.strip() or "unknown"
    except Exception:
        return "unknown"


def get_vivado_version():
    try:
        r = subprocess.run(
            vivado("-version"),
            capture_output=True, text=True, timeout=15,
        )
        # First line is e.g. "Vivado v2023.2 (64-bit)"
        m = re.search(r"Vivado\s+v(\S+)", r.stdout)
        return m.group(1) if m else "unknown"
    except Exception:
        return "unknown"


def utc_stamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# Vivado invocation
# ---------------------------------------------------------------------------
def build_bitstream(loop, force):
    """Ensure vivado_uart_L${loop}/sha256_stream_uart_top.bit exists.
    Returns the bitfile path."""
    outdir = REPO_ROOT / f"vivado_uart_L{loop}"
    bit    = outdir / "sha256_stream_uart_top.bit"
    if bit.exists() and not force:
        print(f"  [build] LOOP={loop}: reusing existing bitstream")
        return bit
    print(f"  [build] LOOP={loop}: running vivado -mode batch -source synth/uart.tcl ...")
    cmd = vivado("-mode", "batch",
                 "-source", str(UART_TCL),
                 "-tclargs", str(loop))
    r = subprocess.run(cmd, cwd=REPO_ROOT)
    if r.returncode != 0 or not bit.exists():
        raise RuntimeError(f"Bitstream build failed for LOOP={loop}")
    return bit


def build_bscan_bitstream(loop, force):
    """Ensure vivado_bscan_L${loop}/sha256_stream_bscan_top.bit exists."""
    outdir = REPO_ROOT / f"vivado_bscan_L{loop}"
    bit    = outdir / "sha256_stream_bscan_top.bit"
    if bit.exists() and not force:
        print(f"  [build] LOOP={loop}: reusing existing BSCAN bitstream")
        return bit
    print(f"  [build] LOOP={loop}: running vivado -mode batch -source synth/bscan.tcl ...")
    cmd = vivado("-mode", "batch",
                 "-source", str(BSCAN_TCL),
                 "-tclargs", str(loop))
    r = subprocess.run(cmd, cwd=REPO_ROOT)
    if r.returncode != 0 or not bit.exists():
        raise RuntimeError(f"BSCAN bitstream build failed for LOOP={loop}")
    return bit


def read_bscan_digests(bit, nstreams):
    """Program the FPGA and read digests back via BSCAN USER1.

    Invokes bench/program_bscan.tcl via Vivado batch mode, which programs the
    device and prints STREAM/ROOT lines to stdout.  Returns a list of those
    lines (same format as read_uart_digests).
    """
    cmd = vivado("-mode", "batch",
                 "-source", str(PROG_BSCAN_TCL),
                 "-tclargs", str(bit), str(nstreams))
    r = subprocess.run(cmd, cwd=REPO_ROOT, capture_output=True, text=True,
                       timeout=300)
    if r.returncode != 0:
        raise RuntimeError(
            f"program_bscan.tcl failed (rc={r.returncode}):\n{r.stderr[-2000:]}"
        )
    return [ln for ln in r.stdout.splitlines() if DIGEST_LINE.match(ln)]


def program_bitstream(bit):
    """Flash a bitfile onto the board via Vivado hw_manager."""
    print(f"  [prog]  {bit.name}")
    cmd = vivado("-mode", "batch",
                 "-source", str(PROG_TCL),
                 "-tclargs", str(bit))
    r = subprocess.run(cmd, cwd=REPO_ROOT)
    if r.returncode != 0:
        raise RuntimeError(f"Programming failed for {bit}")


# ---------------------------------------------------------------------------
# UART readback
# ---------------------------------------------------------------------------
DIGEST_LINE = re.compile(r"^(STREAM \d\d|ROOT      )\s*=\s*([0-9a-f]{64})\s*$")


def read_uart_digests(ser, nstreams):
    """Read `nstreams` STREAM lines + 1 ROOT line from a pre-opened serial port.

    `ser` must already be open with the correct timeout set. The caller is
    responsible for opening the port *before* programming the FPGA so that the
    kernel TTY buffer captures UART output during the Vivado teardown window.

    Returns list of raw lines (STREAM+ROOT only, in order). Raises TimeoutError
    on incomplete capture.
    """
    lines = []
    while len(lines) < nstreams + 1:
        raw = ser.readline()
        if not raw:
            raise TimeoutError(
                f"Serial read timed out after {len(lines)}/{nstreams+1} lines"
            )
        s = raw.decode("ascii", errors="replace").rstrip("\r\n")
        if DIGEST_LINE.match(s):
            lines.append(s)
    return lines


# ---------------------------------------------------------------------------
# Golden
# ---------------------------------------------------------------------------
def compute_golden(loop):
    env = os.environ.copy()
    env["LOOP"] = str(loop)
    r = subprocess.run(
        [sys.executable, str(REF_PY)],
        env=env, capture_output=True, text=True, timeout=120,
    )
    if r.returncode != 0:
        raise RuntimeError(f"ref_stream.py failed: {r.stderr}")
    return [ln for ln in r.stdout.splitlines() if DIGEST_LINE.match(ln)]


def diff_digests(rtl_lines, ref_lines, nstreams):
    """Return (all_match, root_match, streams_matched, first_diff)."""
    # Both lists have nstreams STREAM lines then 1 ROOT line.
    if len(rtl_lines) != nstreams + 1 or len(ref_lines) != nstreams + 1:
        return False, False, 0, f"length mismatch: rtl={len(rtl_lines)} ref={len(ref_lines)}"

    streams_matched = sum(
        1 for r, g in zip(rtl_lines[:nstreams], ref_lines[:nstreams]) if r == g
    )
    root_match = (rtl_lines[nstreams] == ref_lines[nstreams])
    all_match  = (streams_matched == nstreams) and root_match

    first_diff = ""
    if not all_match:
        for i, (r, g) in enumerate(zip(rtl_lines, ref_lines)):
            if r != g:
                first_diff = f"line {i}: rtl={r!r} ref={g!r}"
                break
    return all_match, root_match, streams_matched, first_diff


# ---------------------------------------------------------------------------
# CSV
# ---------------------------------------------------------------------------
CSV_FIELDS = [
    "loop", "nstreams",
    "lut", "ff", "bram_36k", "dsp",
    # Per-functional-block breakdown (see synth/uart.tcl for how each is defined;
    # `rest` is the derived bucket = total minus all the named blocks).
    "lut_core",      "ff_core",
    "lut_uart",      "ff_uart",
    "lut_state_ram", "ff_state_ram",
    "lut_lfsr",      "ff_lfsr",
    "lut_divider",   "ff_divider",
    "lut_rest",      "ff_rest",
    "wns_ns", "tns_ns", "target_period_ns", "fmax_mhz", "throughput_gbps",
    "ref_match", "root_match", "streams_matched",
    "git_sha", "timestamp_utc", "vivado_version", "elapsed_s",
]


def append_csv(row):
    write_header = not CSV_PATH.exists()
    with open(CSV_PATH, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        if write_header:
            w.writeheader()
        w.writerow(row)


# ---------------------------------------------------------------------------
# Per-LOOP sweep step
# ---------------------------------------------------------------------------
def run_one(loop, args, provenance):
    start = time.time()
    nstreams = 64 // loop

    if args.bscan:
        bit    = build_bscan_bitstream(loop, args.rebuild)
        outdir = REPO_ROOT / f"vivado_bscan_L{loop}"
    else:
        bit    = build_bitstream(loop, args.rebuild)
        outdir = REPO_ROOT / f"vivado_uart_L{loop}"

    util   = parse_utilization(str(outdir / "util.rpt"))
    tim    = parse_timing(str(outdir / "timing.rpt"))
    blocks = parse_block_breakdown(str(outdir))

    # Both wrappers run on clk_div2 (62.5 MHz, 16 ns period).
    target_period = 16.0
    fmax = throughput = None
    if tim["wns_ns"] is not None:
        achieved_period = target_period - tim["wns_ns"]
        if achieved_period > 0:
            fmax = 1000.0 / achieved_period
            throughput = 512.0 * fmax / loop / 1000.0

    if args.bscan:
        # BSCAN: program_bscan.tcl handles programming + readback in one call.
        try:
            rtl_lines = read_bscan_digests(bit, nstreams)
        except Exception as e:
            print(f"  [read]  FAIL: {e}")
            rtl_lines = []
    else:
        # UART: open serial port before programming so the kernel TTY buffer
        # captures output during Vivado's hw_manager teardown window.
        with serial.Serial(args.port, baudrate=115200,
                           timeout=args.read_timeout) as ser:
            ser.reset_input_buffer()
            program_bitstream(bit)
            try:
                rtl_lines = read_uart_digests(ser, nstreams)
            except TimeoutError as e:
                print(f"  [read]  FAIL: {e}")
                rtl_lines = []

    ref_lines = compute_golden(loop)
    all_match, root_match, streams_matched, first_diff = diff_digests(
        rtl_lines, ref_lines, nstreams
    )
    if not all_match and first_diff:
        print(f"  [diff]  {first_diff}")

    elapsed = time.time() - start
    row = {
        "loop":             loop,
        "nstreams":         nstreams,
        "lut":              util["lut"],
        "ff":               util["ff"],
        "bram_36k":         util["bram_36k"],
        "dsp":              util["dsp"],
        "lut_core":         blocks["core"]["lut"],
        "ff_core":          blocks["core"]["ff"],
        "lut_uart":         blocks["uart"]["lut"],
        "ff_uart":          blocks["uart"]["ff"],
        "lut_state_ram":    blocks["state_ram"]["lut"],
        "ff_state_ram":     blocks["state_ram"]["ff"],
        "lut_lfsr":         blocks["lfsr"]["lut"],
        "ff_lfsr":          blocks["lfsr"]["ff"],
        "lut_divider":      blocks["divider"]["lut"],
        "ff_divider":       blocks["divider"]["ff"],
        "lut_rest":         blocks["rest"]["lut"],
        "ff_rest":          blocks["rest"]["ff"],
        "wns_ns":           tim["wns_ns"],
        "tns_ns":           tim["tns_ns"],
        "target_period_ns": target_period,
        "fmax_mhz":         f"{fmax:.1f}" if fmax else "",
        "throughput_gbps":  f"{throughput:.2f}" if throughput else "",
        "ref_match":        "PASS" if all_match else "FAIL",
        "root_match":       "PASS" if root_match else "FAIL",
        "streams_matched":  f"{streams_matched}/{nstreams}",
        "git_sha":          provenance["git_sha"],
        "timestamp_utc":    utc_stamp(),
        "vivado_version":   provenance["vivado_version"],
        "elapsed_s":        f"{elapsed:.1f}",
    }
    append_csv(row)
    return row


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def parse_args():
    p = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    p.add_argument("--port", default=None,
                   help="serial port for UART mode (e.g. /dev/ttyUSB1, COM6)")
    p.add_argument("--bscan", action="store_true",
                   help="use BSCAN JTAG readback (no UART adapter required)")
    p.add_argument("--loops", default="1,2,4,8,16,32,64",
                   help="comma-separated LOOP values to sweep")
    p.add_argument("--rebuild", action="store_true",
                   help="rebuild bitstreams even if they already exist")
    p.add_argument("--read-timeout", type=float, default=10.0,
                   help="per-line serial read timeout in seconds (UART mode only)")
    return p.parse_args()


def main():
    args = parse_args()

    if not args.bscan and not args.port:
        sys.exit("ERROR: supply --port <device> for UART mode or --bscan for JTAG readback")
    if not args.bscan and not _SERIAL_AVAILABLE:
        sys.exit("ERROR: pyserial not installed. Run: pip install pyserial")

    loops = [int(x) for x in args.loops.split(",")]
    for L in loops:
        if L not in LEGAL_LOOPS:
            sys.exit(f"LOOP={L} not in {LEGAL_LOOPS}")

    provenance = {
        "git_sha":        get_git_sha(),
        "vivado_version": get_vivado_version(),
    }
    mode = "BSCAN" if args.bscan else f"UART {args.port}"
    print(f"Sweep: loops={loops} mode={mode} git={provenance['git_sha']} "
          f"vivado={provenance['vivado_version']}")
    print(f"CSV → {CSV_PATH}")

    rows = []
    for L in loops:
        print(f"\n=== LOOP={L} (NSTREAMS={64//L}) ===")
        try:
            row = run_one(L, args, provenance)
        except Exception as e:
            print(f"  [ERROR] LOOP={L}: {e}")
            row = {"loop": L, "nstreams": 64//L, "ref_match": "ERROR"}
        rows.append(row)

    # Final summary table
    print("\n" + "=" * 84)
    print(f"{'LOOP':>4} {'NSTR':>5} {'LUT':>7} {'FF':>7} {'BRAM':>5} {'DSP':>4} "
          f"{'Fmax':>7} {'Gbps':>7} {'REF':>6} {'ROOT':>6} {'STR':>7} {'t(s)':>7}")
    print("-" * 84)
    for r in rows:
        print(f"{r.get('loop',''):>4} {r.get('nstreams',''):>5} "
              f"{r.get('lut',''):>7} {r.get('ff',''):>7} "
              f"{r.get('bram_36k',''):>5} {r.get('dsp',''):>4} "
              f"{r.get('fmax_mhz',''):>7} {r.get('throughput_gbps',''):>7} "
              f"{r.get('ref_match',''):>6} {r.get('root_match',''):>6} "
              f"{r.get('streams_matched',''):>7} {r.get('elapsed_s',''):>7}")
    print("=" * 84)
    passes = sum(1 for r in rows if r.get("ref_match") == "PASS")
    print(f"{passes}/{len(rows)} LOOPs PASS")
    sys.exit(0 if passes == len(rows) else 1)


if __name__ == "__main__":
    main()
