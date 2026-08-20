# Program a bitstream and read back SHA-256 digests via BSCAN USER1.
#
# Usage:
#   vivado -mode batch -source bench/program_bscan.tcl \
#          -tclargs <bitfile> <nstreams>
#
# Prints NSTREAMS STREAM lines and one ROOT line to stdout in the same format
# as the UART wrapper, so hw_sweep.py can parse them with the same regex:
#   STREAM 00 = <64-hex-chars>
#   ...
#   STREAM <N-1> = <64-hex-chars>
#   ROOT      = <64-hex-chars>
#
# Each 257-bit scan returns:
#   bit 0                     : done (1 when DUT has finished)
#   bits [256:1]              : currently selected 256-bit digest
#
# TDI supplies the selector for the next scan. Selectors 0..NSTREAMS-1 map to
# streams, and NSTREAMS maps to the root. scan_dr_hw_jtag returns hexadecimal,
# which decode_scan treats as one arbitrary-precision Tcl integer.

if {[llength $argv] < 2} {
    error "Usage: vivado -mode batch -source bench/program_bscan.tcl \
-tclargs <bitfile> <nstreams>"
}
set BITFILE  [lindex $argv 0]
set NSTREAMS [lindex $argv 1]

if {![file exists $BITFILE]} {
    error "Bitfile not found: $BITFILE"
}

set SHREG_W 257

# ---------------------------------------------------------------------------
# Program
# ---------------------------------------------------------------------------
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set dev [lindex [get_hw_devices -filter {NAME =~ "*7z020*"}] 0]
if {$dev eq ""} {
    set dev [current_hw_device]
}
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set_property PROGRAM.FILE $BITFILE $dev
program_hw_devices $dev

# The hash finishes in ~103 µs (6464 cycles at 62.5 MHz).  Wait 2 s so the
# sticky done flag and all digest state are stable before BSCAN reads them.
after 2000

# ---------------------------------------------------------------------------
# Read back via BSCAN USER1
# ---------------------------------------------------------------------------
# Low-level IR/DR scans require a hw_jtag object, which Vivado creates only
# when the target is opened in JTAG mode. BSCANE2 JTAG_CHAIN(1) is USER1;
# 7-series USER1 uses the six-bit instruction value 0x02.
set target [current_hw_target]
close_hw_target
open_hw_target -jtag_mode on $target
scan_ir_hw_jtag 6 -tdi 02

# ---------------------------------------------------------------------------
# Parse helpers
# ---------------------------------------------------------------------------
# Return {done digest_hex} from the hexadecimal value returned by a 257-bit
# scan. Tcl integers are arbitrary precision, so the 256-bit shift is exact.
proc decode_scan {tdo_hex} {
    set hex [string tolower [string trim $tdo_hex]]
    set hex [string map [list "_" "" " " "" "\n" "" "\r" "" "\t" ""] $hex]
    if {[string match "0x*" $hex]} {
        set hex [string range $hex 2 end]
    }
    if {![string is xdigit -strict $hex]} {
        error "scan_dr_hw_jtag returned non-hex data: $tdo_hex"
    }
    set value  [expr "0x$hex"]
    set done   [expr {$value & 1}]
    set mask   [expr {(1 << 256) - 1}]
    set digest [expr {($value >> 1) & $mask}]
    return [list $done [format %064x $digest]]
}

# ---------------------------------------------------------------------------
# Print results (streams first, then root — matches ref_stream.py order)
# ---------------------------------------------------------------------------
# read_sel starts at stream 0. Each scan returns the current selection while
# shifting the following selector into TDI for the next Update-DR.
set warned_not_done 0
for {set s 0} {$s < $NSTREAMS} {incr s} {
    set next_sel [expr {$s + 1}]
    set captured [scan_dr_hw_jtag $SHREG_W -tdi [format %x $next_sel]]
    lassign [decode_scan $captured] done digest
    if {!$done && !$warned_not_done} {
        puts stderr "WARNING: BSCAN done bit is 0 — FPGA may not have finished.\
 Increase the after delay or check the bitstream."
        set warned_not_done 1
    }
    puts [format "STREAM %02d = %s" $s $digest]
}

# The final stream scan committed selector NSTREAMS, so this capture is root.
set captured [scan_dr_hw_jtag $SHREG_W -tdi 0]
lassign [decode_scan $captured] root_done root_digest
if {!$root_done && !$warned_not_done} {
    puts stderr "WARNING: BSCAN done bit is 0 — FPGA may not have finished.\
 Increase the after delay or check the bitstream."
}
puts [format "ROOT      = %s" $root_digest]

close_hw_target
close_hw_manager
