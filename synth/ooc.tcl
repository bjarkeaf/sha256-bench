# Vivado out-of-context synthesis + place + route for sha256-bench
#
# Usage:
#   vivado -mode batch -source synth/ooc.tcl -tclargs <LOOP> <N_CORES> [PERIOD_NS] [PART]
#
# Defaults: PERIOD_NS=2.5 (400 MHz), PART=xc7z020clg400-1 (Pynq-Z2)
#
# Outputs (in ./vivado_ooc_L<LOOP>_N<N_CORES>/):
#   util.rpt    - LUT/FF utilization
#   timing.rpt  - timing summary (WNS → achieved Fmax)

set LOOP     [lindex $argv 0]
set N_CORES  [lindex $argv 1]
set PERIOD   [expr {[llength $argv] > 2 ? [lindex $argv 2] : 2.5}]
set PART     [expr {[llength $argv] > 3 ? [lindex $argv 3] : "xc7z020clg400-1"}]

set OUTDIR "vivado_ooc_L${LOOP}_N${N_CORES}"
file mkdir $OUTDIR

puts "=== SHA-256 bench OOC: LOOP=$LOOP N_CORES=$N_CORES PERIOD=${PERIOD}ns PART=$PART ==="

# Read RTL
set RTL_DIR [file normalize [file join [file dirname [info script]] "../rtl"]]
read_verilog "$RTL_DIR/sha256_functions.v"
read_verilog "$RTL_DIR/sha256_transform.v"
read_verilog "$RTL_DIR/bench_top.v"

# Synthesise out-of-context
synth_design \
    -top bench_top \
    -part $PART \
    -mode out_of_context \
    -generic "LOOP=$LOOP" \
    -generic "N_CORES=$N_CORES"

# Post-synthesis utilization
report_utilization -file "$OUTDIR/util_synth.rpt"

# Apply clock constraint and opt/place/route
create_clock -name clk -period $PERIOD [get_ports clk]

opt_design
place_design
route_design

# Reports
report_utilization    -file "$OUTDIR/util.rpt"
report_timing_summary -file "$OUTDIR/timing.rpt" -max_paths 10

puts "=== Done. Reports in $OUTDIR/ ==="
