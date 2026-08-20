`timescale 1ns/1ps

// Board-level BSCAN wrapper for sha256_stream_top targeting the Pynq-Z2.
//
// Runs the streaming SHA-256 scheduler once at power-on, latches the digests
// when done rises, then makes them readable over the existing JTAG USB cable
// via the Xilinx BSCANE2 USER1 scan chain.  No PMOD UART adapter required.
//
// After programming, the laptop calls bench/program_bscan.tcl, which issues
// a scan_dr_hw_jtag command to shift out SHREG_W bits.  The bit layout is:
//
//   [0]                        done_r  (1 if DUT has finished)
//   [256:1]                    root_r[255:0]     (root_r[0] at bit 1)
//   [512:257]                  stream 0 [255:0]
//   [768:513]                  stream 1 [255:0]
//   ...
//   [(NSTREAMS+1)*256 : NSTREAMS*256+1]  stream NSTREAMS-1 [255:0]
//
// Bits shift out LSB-first on TDO; the Tcl parser reverses bytes to
// reconstruct the standard MSB-first SHA-256 hex strings.
//
// LEDs (Pynq-Z2 LD0..LD1):
//   LD0 led_alive  : ~0.5 Hz heartbeat off the divided clock
//   LD1 led_done   : mirrors done_r (set after the run)
//
// Reset is self-generated: rst is high for the first 128 clk_div cycles.

module sha256_stream_bscan_top #(
    parameter integer LOOP = 1
) (
    input  wire clk,        // 125 MHz onboard oscillator (Pynq-Z2 H16)
    output wire led_alive,  // LD0
    output wire led_done    // LD1
);
    localparam integer NSTREAMS = 64 / LOOP;
    // Total shift-register width: 1 done bit + (NSTREAMS+1) 256-bit digests
    localparam integer SHREG_W  = 1 + (NSTREAMS + 1) * 256;

    // ------------------------------------------------------------------
    // 125 → 62.5 MHz clock divider (SHA chain-add path fails at 125 MHz)
    // ------------------------------------------------------------------
    wire clk_div;
    clk_div2 divider (.clk_in(clk), .clk_out(clk_div));

    // ------------------------------------------------------------------
    // Self-clearing reset (128 cycles on clk_div)
    // ------------------------------------------------------------------
    reg [7:0] rst_cnt = 8'd0;
    wire rst = ~rst_cnt[7];
    always @(posedge clk_div)
        if (!rst_cnt[7]) rst_cnt <= rst_cnt + 8'd1;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    wire                    done;
    wire [255:0]            root_digest;
    wire [NSTREAMS*256-1:0] stream_digests_flat;

    sha256_stream_top #(.LOOP(LOOP)) uut (
        .clk                 (clk_div),
        .rst                 (rst),
        .done                (done),
        .root_digest         (root_digest),
        .stream_digests_flat (stream_digests_flat)
    );

    // ------------------------------------------------------------------
    // Latch digests on rising edge of done (clk_div domain).
    // The ASYNC_REG attribute on done_r suppresses Vivado CDC warnings;
    // the actual BSCAN scan happens seconds after done_r is set, so
    // metastability is not a concern.
    // ------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg done_r = 1'b0;
    reg [255:0]             root_r    = 256'd0;
    reg [NSTREAMS*256-1:0]  digests_r;
    initial digests_r = {NSTREAMS*256{1'b0}};

    always @(posedge clk_div) begin
        if (done && !done_r) begin
            done_r    <= 1'b1;
            root_r    <= root_digest;
            digests_r <= stream_digests_flat;
        end
    end

    // ------------------------------------------------------------------
    // BSCAN USER1: expose digests via the JTAG TAP already on the USB cable.
    // DRCK is the gated TCK that runs only during Capture-DR and Shift-DR.
    // ------------------------------------------------------------------
    wire bscan_capture, bscan_drck, bscan_sel, bscan_shift, bscan_tdi;
    wire bscan_tdo;

    BSCANE2 #(.JTAG_CHAIN(1)) bscan_inst (
        .CAPTURE (bscan_capture),
        .DRCK    (bscan_drck),
        .RESET   (),
        .RUNTEST (),
        .SEL     (bscan_sel),
        .SHIFT   (bscan_shift),
        .TCK     (),
        .TDI     (bscan_tdi),
        .TMS     (),
        .UPDATE  (),
        .TDO     (bscan_tdo)
    );

    reg [SHREG_W-1:0] shreg;

    always @(posedge bscan_drck) begin
        if (bscan_sel && bscan_capture)
            // Pack with done_r at bit 0 (shifted out first), root next,
            // then streams in ascending order (stream 0 at bits [512:257]).
            shreg <= {digests_r, root_r, done_r};
        else if (bscan_sel && bscan_shift)
            shreg <= {bscan_tdi, shreg[SHREG_W-1:1]};
    end

    assign bscan_tdo = shreg[0];

    // ------------------------------------------------------------------
    // LEDs
    // ------------------------------------------------------------------
    reg [25:0] hb = 26'd0;
    always @(posedge clk_div) hb <= hb + 26'd1;

    assign led_alive = hb[25];
    assign led_done  = done_r;

endmodule
