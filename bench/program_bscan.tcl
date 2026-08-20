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
# Bit layout in the BSCAN shift register (see rtl/sha256_stream_bscan_top.v):
#   bit 0                     : done_r (1 when DUT has finished)
#   bits [256:1]              : root_r[255:0], LSB first
#   bits [512:257]            : stream 0 [255:0], LSB first
#   bits [768:513]            : stream 1, ...
#   ...
# Bits shift out LSB-first on TDO.  extract_digest reverses byte order to
# produce the standard MSB-first SHA-256 hex string.

if {[llength $argv] < 2} {
    error "Usage: vivado -mode batch -source bench/program_bscan.tcl \
-tclargs <bitfile> <nstreams>"
}
set BITFILE  [lindex $argv 0]
set NSTREAMS [lindex $argv 1]

if {![file exists $BITFILE]} {
    error "Bitfile not found: $BITFILE"
}

set SHREG_W [expr {1 + ($NSTREAMS + 1) * 256}]

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
# done latch is stable well before the BSCAN scan runs.
after 2000

# ---------------------------------------------------------------------------
# Read back via BSCAN USER1
# ---------------------------------------------------------------------------
# scan_dr_hw_jtag shifts SHREG_W bits through the USER1 data register.
# TDI is all zeros (don't care for readback); TDO carries the shift-register
# contents, returned as a string of SHREG_W '0'/'1' characters, LSB first.
set tdo_bits [scan_dr_hw_jtag $SHREG_W \
                  -tdi [string repeat 0 $SHREG_W] $dev]

close_hw_target
close_hw_manager

# ---------------------------------------------------------------------------
# Sanity: check done bit
# ---------------------------------------------------------------------------
if {[string index $tdo_bits 0] ne "1"} {
    puts stderr "WARNING: BSCAN done bit is 0 — FPGA may not have finished.\
 Increase the after delay or check the bitstream."
}

# ---------------------------------------------------------------------------
# Parse helpers
# ---------------------------------------------------------------------------

# Extract a 256-bit SHA-256 digest from the TDO bit string.
# offset: index of the first (LSB) bit of the digest in tdo_bits.
# The digest bits arrive LSB-first; bytes arrive in ascending order (byte 0
# of root_r = LSB byte, byte 31 = MSB byte).  SHA-256 prints MSB byte first,
# so we collect bytes from b=31 downto b=0.
proc extract_digest {bits offset} {
    set hex ""
    for {set b 31} {$b >= 0} {incr b -1} {
        set byte 0
        for {set i 0} {$i < 8} {incr i} {
            if {[string index $bits [expr {$offset + $b*8 + $i}]] eq "1"} {
                set byte [expr {$byte | (1 << $i)}]
            }
        }
        append hex [format %02x $byte]
    }
    return $hex
}

# ---------------------------------------------------------------------------
# Print results (streams first, then root — matches ref_stream.py order)
# ---------------------------------------------------------------------------
# Stream s is at bit offset 257 + s*256 (after done[0] and root[256:1]).
for {set s 0} {$s < $NSTREAMS} {incr s} {
    set offset [expr {257 + $s * 256}]
    puts [format "STREAM %02d = %s" $s [extract_digest $tdo_bits $offset]]
}

# Root is at bit offset 1 (immediately after done bit).
puts [format "ROOT      = %s" [extract_digest $tdo_bits 1]]
