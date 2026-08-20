# Program a bitstream onto the first attached JTAG device.
#
# Usage:
#   vivado -mode batch -source bench/program.tcl -tclargs <path/to/design.bit>
#
# Used by bench/hw_sweep.py to flash each per-LOOP bitstream unattended.

if {[llength $argv] < 1} {
    error "Usage: vivado -mode batch -source bench/program.tcl -tclargs <bitfile>"
}
set BITFILE [lindex $argv 0]
if {![file exists $BITFILE]} {
    error "Bitfile not found: $BITFILE"
}

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

# Pynq-Z2 exposes the PL as the second device on the chain (the Zynq PS is
# first). current_hw_device defaults to whichever `open_hw_target` chose;
# grab the xc7z020_1 explicitly so we don't accidentally try to program the
# PS ARM.
set dev [lindex [get_hw_devices -filter {NAME =~ "*7z020*"}] 0]
if {$dev eq ""} {
    # Fallback: use whatever the tool selected.
    set dev [current_hw_device]
}
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set_property PROGRAM.FILE $BITFILE $dev
program_hw_devices $dev
refresh_hw_device $dev

close_hw_target
close_hw_manager

puts "=== Programmed $BITFILE onto [get_property PART $dev] ==="
