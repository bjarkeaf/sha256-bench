# Vivado full flow for sha256_stream_uart_top on Pynq-Z2.
# Reads RTL + XDC, synthesises for a given LOOP, places, routes, writes
# bitstream + reports.
#
# Usage:
#   vivado -mode batch -source synth/uart.tcl -tclargs <LOOP>
#
# LOOP must be one of {1, 2, 4, 8, 16, 32} (divisor of 64). Defaults to 1.
#
# Outputs (in ./vivado_uart_L${LOOP}/):
#   sha256_stream_uart_top.bit  - flash to the Pynq-Z2 via Vivado Hardware Manager
#   util.rpt                    - final LUT/FF/BRAM/DSP utilization
#   timing.rpt                  - timing summary (WNS/TNS on sys_clk)

set LOOP [expr {[llength $argv] > 0 ? [lindex $argv 0] : 1}]
if {[lsearch {1 2 4 8 16 32} $LOOP] < 0} {
    error "LOOP=$LOOP not in {1,2,4,8,16,32}"
}

set OUTDIR "vivado_uart_L${LOOP}"
file mkdir $OUTDIR

set PART "xc7z020clg400-1"

set RTL_DIR [file normalize [file join [file dirname [info script]] "../rtl"]]
set XDC     [file normalize [file join [file dirname [info script]] "uart.xdc"]]

read_verilog "$RTL_DIR/sha256_functions.v"
read_verilog "$RTL_DIR/sha256_transform.v"
read_verilog "$RTL_DIR/sha256_stream_top.v"
read_verilog "$RTL_DIR/uart_tx.v"
read_verilog "$RTL_DIR/sha256_stream_uart_top.v"
read_xdc     $XDC

puts "=== SHA-256 stream UART: synthesising LOOP=$LOOP for $PART ==="

synth_design \
    -top sha256_stream_uart_top \
    -part $PART \
    -generic "LOOP=$LOOP"
report_utilization -file "$OUTDIR/util_synth.rpt"

opt_design
place_design
route_design

report_utilization    -file "$OUTDIR/util.rpt"
report_utilization    -file "$OUTDIR/util_hier.rpt" -hierarchical
report_timing_summary -file "$OUTDIR/timing.rpt" -max_paths 10

write_bitstream -force "$OUTDIR/sha256_stream_uart_top.bit"

puts "=== Done. Bitstream and reports in $OUTDIR/ ==="
