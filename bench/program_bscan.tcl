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
# Low-level IR/DR scans operate on the WHOLE JTAG chain, not just the PL
# device.  Zynq-7000 exposes the ARM Cortex-A9 DAP TAP alongside the PL TAP,
# so USER1 (6-bit 0x02) must be sandwiched between BYPASS instructions for
# every other device in the chain.  Same for DR: each other device
# contributes 1 BYPASS bit.  Shifting only 6 IR bits corrupts both TAPs and
# lands them in BYPASS, at which point every DR scan just shuttles TDI
# through BYPASS and comes back as garbage (e.g. STREAM 00 = 0...0002 when
# we shift in selector 1 through 2 BYPASS bits).
set target [current_hw_target]
close_hw_target
open_hw_target -jtag_mode on $target

# Enumerate the chain.  get_hw_devices returns devices in JTAG order from
# TDI (index 0) to TDO (last index).  When shifting an integer with -tdi,
# the LSB is shifted in first and lands in the device NEAREST TDO (last in
# the list).  So the offset of device i in the concatenated IR word is the
# sum of IR lengths of devices at HIGHER indices.
# Determine IR length for a device. Property names vary across Vivado
# versions, so probe a few and fall back to name-based defaults (ARM Cortex
# DAPs are always 4-bit IR, 7-series PL TAPs are always 6-bit).
proc device_ir_len {d} {
    foreach prop {REGISTER.JTAG.IR_LENGTH IR_LENGTH JTAG.IR_LENGTH} {
        if {![catch {get_property $prop $d} val] && $val ne ""} {
            return $val
        }
    }
    set n [string tolower [get_property NAME $d]]
    if {[string match "*arm*" $n] || [string match "*dap*" $n]} { return 4 }
    if {[string match "*7z*" $n]  || [string match "*xc7*" $n]}  { return 6 }
    error "Unknown IR length for device [get_property NAME $d]"
}

set devices [get_hw_devices]
puts "JTAG chain has [llength $devices] device(s):"
set our_idx      -1
set total_ir_len 0
set ir_lens      {}
set idx 0
foreach d $devices {
    set ir_len [device_ir_len $d]
    set name   [get_property NAME $d]
    lappend ir_lens $ir_len
    puts [format "  \[%d\] %s IR_LEN=%d" $idx $name $ir_len]
    if {[string match "*7z020*" $name] || [string match "*xc7z*" $name]} {
        set our_idx $idx
    }
    incr total_ir_len $ir_len
    incr idx
}
if {$our_idx < 0} {
    error "Could not find PL device (*7z020* or *xc7z*) in JTAG chain"
}

# Compute our device's IR offset (bit position in the ir_val LSB-first word).
set our_ir_offset 0
for {set i [expr {$our_idx + 1}]} {$i < [llength $devices]} {incr i} {
    incr our_ir_offset [lindex $ir_lens $i]
}
set num_dev  [llength $devices]
set all_ones [expr {(1 << $total_ir_len) - 1}]
# BYPASS everywhere, then punch USER1 (0x02) into our 6-bit slot.
set clear_mask [expr {~(0x3F << $our_ir_offset) & $all_ones}]
set ir_val     [expr {($all_ones & $clear_mask) | (0x02 << $our_ir_offset)}]
puts [format "IR: our device idx=%d, offset=%d in %d-bit IR, ir_val=0x%x" \
             $our_idx $our_ir_offset $total_ir_len $ir_val]
scan_ir_hw_jtag $total_ir_len -tdi [format %x $ir_val]

# DR: our 257-bit USER1 register plus 1 BYPASS bit per other device.  Same
# ordering: bits shifted in first (LSB of dr_val) end up nearest TDO.  Our
# DR offset = number of devices at indices > our_idx.
set our_dr_offset [expr {$num_dev - $our_idx - 1}]
set dr_total      [expr {257 + $num_dev - 1}]
puts [format "DR: total=%d bits, our 257-bit slot at offset %d" \
             $dr_total $our_dr_offset]

# ---------------------------------------------------------------------------
# Parse helpers
# ---------------------------------------------------------------------------
# Return {done digest_hex} from the hexadecimal value returned by a full-chain
# DR scan.  Extracts our 257-bit slot at $our_dr_offset first, then splits
# into done (bit 0) and digest (bits 256:1).
#
# NOTE: We use hex constants for the masks instead of `(1 << 256) - 1`, because
# Vivado 2026.1's Tcl `expr` computes bit shifts >64 as wide-int (silently
# truncated to 64 bits), which turned mask_256 into 0xffffffff and threw away
# the top 224 bits of every digest.  Written as hex literals, Tcl treats them
# as bignums directly and the arithmetic is exact.
set MASK_256 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
set MASK_257 0x1ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff

proc decode_scan {tdo_hex dr_offset} {
    global MASK_256 MASK_257
    set hex [string tolower [string trim $tdo_hex]]
    set hex [string map [list "_" "" " " "" "\n" "" "\r" "" "\t" ""] $hex]
    if {[string match "0x*" $hex]} {
        set hex [string range $hex 2 end]
    }
    if {![string is xdigit -strict $hex]} {
        error "scan_dr_hw_jtag returned non-hex data: $tdo_hex"
    }
    set full   [expr "0x$hex"]
    set slot   [expr {($full >> $dr_offset) & $MASK_257}]
    set done   [expr {$slot & 1}]
    set digest [expr {($slot >> 1) & $MASK_256}]
    return [list $done [format %064x $digest]]
}

# Compose a full-chain DR TDI word from our device's 257-bit TDI value.  Our
# slot sits at $our_dr_offset; the extra BYPASS bits can be anything (0).
proc make_dr_tdi {slot_val dr_offset} {
    return [format %x [expr {$slot_val << $dr_offset}]]
}

# ---------------------------------------------------------------------------
# Print results (streams first, then root — matches ref_stream.py order)
# ---------------------------------------------------------------------------
# read_sel starts at stream 0. Each scan returns the current selection while
# shifting the following selector into TDI for the next Update-DR.
set warned_not_done 0
for {set s 0} {$s < $NSTREAMS} {incr s} {
    set next_sel [expr {$s + 1}]
    set captured [scan_dr_hw_jtag $dr_total \
                     -tdi [make_dr_tdi $next_sel $our_dr_offset]]
    lassign [decode_scan $captured $our_dr_offset] done digest
    if {!$done && !$warned_not_done} {
        puts stderr "WARNING: BSCAN done bit is 0 — FPGA may not have finished.\
 Increase the after delay or check the bitstream."
        set warned_not_done 1
    }
    puts [format "STREAM %02d = %s" $s $digest]
}

# The final stream scan committed selector NSTREAMS, so this capture is root.
set captured [scan_dr_hw_jtag $dr_total \
                 -tdi [make_dr_tdi 0 $our_dr_offset]]
lassign [decode_scan $captured $our_dr_offset] root_done root_digest
if {!$root_done && !$warned_not_done} {
    puts stderr "WARNING: BSCAN done bit is 0 — FPGA may not have finished.\
 Increase the after delay or check the bitstream."
}
puts [format "ROOT      = %s" $root_digest]

close_hw_target
close_hw_manager
