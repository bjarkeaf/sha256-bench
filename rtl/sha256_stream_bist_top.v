`timescale 1ns/1ps

// Board-level BIST wrapper for sha256_stream_top targeting the Pynq-Z2.
//
// Runs the streaming SHA-256 scheduler once on the fixed LFSR seeds baked into
// sha256_stream_top.v, then compares root_digest against a golden root
// pre-computed by sim/ref_stream_lib.py (byte-identical to sim/ref_stream.py).
// Result is latched onto onboard LEDs so the board self-reports without any
// host software.
//
// LEDs (Pynq-Z2 LD0..LD3):
//   LD0 led_match    : latched high when done && root_digest == GOLDEN_ROOT
//   LD1 led_done     : mirrors sha256_stream_top.done (high after the run)
//   LD2 led_mismatch : latched high when done rises with a NON-matching root
//   LD3 led_alive    : ~0.5 Hz heartbeat off the divided clock (blinks ~1/2 s)
//
// The streaming wrapper's chain-add path caps at ~75 MHz on this device, so
// the design runs on a 62.5 MHz divided clock (see rtl/clk_div2.v). Total
// runtime is ~104 us (6464 cycles @ 62.5 MHz).
//
// Expected LED pattern:
//   LD3 blinking always     -> clock and configuration are alive
//   LD1 on                  -> pipeline finished
//   LD0 on, LD2 off         -> PASS (hardware matches Python golden)
//   LD0 off, LD2 on         -> FAIL (root differs from golden)
//
// Reset is self-generated so no board button is required: rst is held high
// for the first 128 cycles after configuration, then released.

module sha256_stream_bist_top (
    input  wire clk,           // 125 MHz onboard oscillator (Pynq-Z2 H16)
    output wire led_match,     // LD0
    output wire led_done,      // LD1
    output wire led_mismatch,  // LD2
    output wire led_alive      // LD3
);

    // Golden root from sim/ref_stream_lib.py at LOOP=1.
    localparam [255:0] GOLDEN_ROOT =
        256'h0f23032ff262f4c307f3558ee675a9ea347b838c22ac21e506bf6bd17f563daa;

    // Divide 125 MHz down to 62.5 MHz. See rtl/clk_div2.v.
    wire clk_div;
    clk_div2 divider (.clk_in(clk), .clk_out(clk_div));

    // Self-clearing reset on the divided clock. rst high while the top bit
    // of rst_cnt is 0, then low forever once rst_cnt saturates. Initial
    // value is applied by Xilinx configuration so there's no X on the first
    // cycle.
    reg [7:0] rst_cnt = 8'd0;
    wire rst = ~rst_cnt[7];
    always @(posedge clk_div)
        if (!rst_cnt[7]) rst_cnt <= rst_cnt + 8'd1;

    wire done;
    wire [255:0] root_digest;

    sha256_stream_top uut (
        .clk                 (clk_div),
        .rst                 (rst),
        .done                (done),
        .root_digest         (root_digest),
        .stream_digests_flat ()  // per-stream digests unused for BIST
    );

    // Capture pass/fail exactly once, the first time done goes high.
    reg match_r    = 1'b0;
    reg mismatch_r = 1'b0;
    always @(posedge clk_div) begin
        if (done && !match_r && !mismatch_r) begin
            if (root_digest == GOLDEN_ROOT) match_r    <= 1'b1;
            else                            mismatch_r <= 1'b1;
        end
    end

    // Free-running heartbeat so a dead LED is obviously distinguishable from
    // "still running." 62.5 MHz / 2^27 ~= 0.46 Hz.
    reg [26:0] hb = 27'd0;
    always @(posedge clk_div) hb <= hb + 27'd1;

    assign led_match    = match_r;
    assign led_done     = done;
    assign led_mismatch = mismatch_r;
    assign led_alive    = hb[26];

endmodule
