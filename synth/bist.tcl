# Vivado full flow for sha256_stream_bist_top on Pynq-Z2.
# Reads RTL + XDC, synthesises, places, routes, writes bitstream.
#
# Usage:
#   vivado -mode batch -source synth/bist.tcl
#
# Outputs (in ./vivado_bist/):
#   sha256_stream_bist_top.bit  - flash to the Pynq-Z2 via Vivado Hardware Manager
#   util.rpt                    - final LUT/FF utilization
#   timing.rpt                  - timing summary (WNS should be well positive
#                                 at 125 MHz; SHA-256 LOOP=1 hits ~400 MHz)

set OUTDIR "vivado_bist"
file mkdir $OUTDIR

set PART "xc7z020clg400-1"

set RTL_DIR [file normalize [file join [file dirname [info script]] "../rtl"]]
set XDC     [file normalize [file join [file dirname [info script]] "bist.xdc"]]

read_verilog "$RTL_DIR/sha256_functions.v"
read_verilog "$RTL_DIR/sha256_transform.v"
read_verilog "$RTL_DIR/sha256_stream_top.v"
read_verilog "$RTL_DIR/sha256_stream_bist_top.v"
read_xdc     $XDC

puts "=== SHA-256 stream BIST: synthesising for $PART ==="

synth_design -top sha256_stream_bist_top -part $PART
report_utilization -file "$OUTDIR/util_synth.rpt"

opt_design
place_design
route_design

report_utilization    -file "$OUTDIR/util.rpt"
report_timing_summary -file "$OUTDIR/timing.rpt" -max_paths 10

write_bitstream -force "$OUTDIR/sha256_stream_bist_top.bit"

puts "=== Done. Bitstream and reports in $OUTDIR/ ==="
