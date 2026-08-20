# Vivado full flow for sha256_stream_bscan_top on Pynq-Z2.
# Reads RTL + XDC, synthesises for a given LOOP, places, routes, writes
# bitstream + reports.  Readback is via BSCAN JTAG, so no PMOD UART adapter
# is required.
#
# Usage:
#   vivado -mode batch -source synth/bscan.tcl -tclargs <LOOP>
#
# LOOP must be one of {1, 2, 4, 8, 16, 32, 64} (divisor of 64). Defaults to 1.
#
# Outputs (in ./vivado_bscan_L${LOOP}/):
#   sha256_stream_bscan_top.bit - flash to the Pynq-Z2 via Vivado Hardware Manager
#   util.rpt                    - total LUT/FF/BRAM/DSP utilization
#   util_hier.rpt               - full hierarchical breakdown
#   util_synth.rpt              - post-synthesis utilization (before P&R)
#   util_core.rpt               - just sha256_transform (compression core)
#   util_bscan.rpt              - BSCAN primitive, selector/mux, and scan register
#   util_state_ram.rpt          - all state_ram register cells
#   util_lfsr.rpt               - all lfsr register cells
#   util_divider.rpt            - just clk_div2
#   timing.rpt                  - timing summary (WNS/TNS on clk_div2)

set LOOP [expr {[llength $argv] > 0 ? [lindex $argv 0] : 1}]
if {[lsearch {1 2 4 8 16 32 64} $LOOP] < 0} {
    error "LOOP=$LOOP not in {1,2,4,8,16,32,64}"
}

set OUTDIR "vivado_bscan_L${LOOP}"
file mkdir $OUTDIR

set PART "xc7z020clg400-1"

set RTL_DIR [file normalize [file join [file dirname [info script]] "../rtl"]]
set XDC     [file normalize [file join [file dirname [info script]] "bscan.xdc"]]

read_verilog "$RTL_DIR/sha256_functions.v"
read_verilog "$RTL_DIR/sha256_transform.v"
read_verilog "$RTL_DIR/sha256_stream_top.v"
read_verilog "$RTL_DIR/clk_div2.v"
read_verilog "$RTL_DIR/sha256_stream_bscan_top.v"
read_xdc     $XDC

puts "=== SHA-256 stream BSCAN: synthesising LOOP=$LOOP for $PART ==="

synth_design \
    -top sha256_stream_bscan_top \
    -part $PART \
    -generic "LOOP=$LOOP"
report_utilization -file "$OUTDIR/util_synth.rpt"

opt_design
place_design
route_design

report_utilization    -file "$OUTDIR/util.rpt"
report_utilization    -file "$OUTDIR/util_hier.rpt" -hierarchical
report_timing_summary -file "$OUTDIR/timing.rpt" -max_paths 10

# Per-functional-block breakdowns.  Same pattern as synth/uart.tcl, with
# util_uart replaced by util_bscan (selector/mux, scan register, and BSCANE2).
foreach {label filter} {
    core      {module_hier uut/core}
    bscan     {module_hier readback}
    state_ram {name        *state_ram*}
    lfsr      {name        *lfsr*}
    divider   {module_hier divider}
} {
    set kind  [lindex $filter 0]
    set match [lindex $filter 1]
    set path  "$OUTDIR/util_$label.rpt"
    if {[catch {
        if {$kind eq "module_hier"} {
            set cells [get_cells $match]
        } else {
            set cells [get_cells -hierarchical -filter "NAME =~ \"$match\""]
        }
        if {[llength $cells] > 0} {
            report_utilization -cells $cells -file $path
        } else {
            close [open $path w]
        }
    } err]} {
        puts "WARNING: util_$label breakdown failed: $err"
    }
}

write_bitstream -force "$OUTDIR/sha256_stream_bscan_top.bit"

puts "=== Done. Bitstream and reports in $OUTDIR/ ==="
