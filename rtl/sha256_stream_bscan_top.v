`timescale 1ns/1ps

// Board-level BSCAN wrapper for sha256_stream_top targeting the Pynq-Z2.
//
// Runs the streaming SHA-256 scheduler once at power-on, then makes its stable
// results readable one at a time over the existing JTAG USB cable via the
// Xilinx BSCANE2 USER1 scan chain.  No PMOD UART adapter required.
//
// Each 257-bit DR scan captures:
//
//   [0]       done
//   [256:1]   selected digest
//
// TDI carries the selector to use on the next scan: 0..NSTREAMS-1 selects a
// stream and NSTREAMS selects the root.  This avoids duplicating every digest
// into a second result bank and a giant BSCAN shift register.
//
// LEDs (Pynq-Z2 LD0..LD1):
//   LD0 led_alive  : ~0.5 Hz heartbeat off the divided clock
//   LD1 led_done   : mirrors the DUT's sticky done output
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
    // BSCAN USER1: expose one selected digest per 257-bit JTAG scan.
    // Keeping the readback logic in one hierarchy also makes util_bscan.rpt
    // account for its selector/mux, scan register, and primitive together.
    // ------------------------------------------------------------------
    bscan_digest_readback #(.NSTREAMS(NSTREAMS)) readback (
        .done(done),
        .root_digest(root_digest),
        .stream_digests_flat(stream_digests_flat)
    );

    // ------------------------------------------------------------------
    // LEDs
    // ------------------------------------------------------------------
    reg [25:0] hb = 26'd0;
    always @(posedge clk_div) hb <= hb + 26'd1;

    assign led_alive = hb[25];
    assign led_done  = done;

endmodule


module bscan_digest_readback #(
    parameter integer NSTREAMS = 64,
    parameter integer SEL_W    = $clog2(NSTREAMS + 1)
) (
    input wire                         done,
    input wire [255:0]                 root_digest,
    input wire [NSTREAMS*256-1:0]      stream_digests_flat
);
    wire bscan_capture, bscan_drck, bscan_sel, bscan_shift, bscan_tdi;
    wire bscan_tck, bscan_update;
    wire bscan_tdo;

    BSCANE2 #(.JTAG_CHAIN(1)) bscan_inst (
        .CAPTURE (bscan_capture),
        .DRCK    (bscan_drck),
        .RESET   (),
        .RUNTEST (),
        .SEL     (bscan_sel),
        .SHIFT   (bscan_shift),
        .TCK     (bscan_tck),
        .TDI     (bscan_tdi),
        .TMS     (),
        .UPDATE  (bscan_update),
        .TDO     (bscan_tdo)
    );

    reg [SEL_W-1:0] read_sel = {SEL_W{1'b0}};
    wire [255:0] selected_digest =
        (read_sel < NSTREAMS)
            ? stream_digests_flat[read_sel*256 +: 256]
            : root_digest;

    reg [256:0] shreg = 257'd0;

    always @(posedge bscan_drck) begin
        if (bscan_sel && bscan_capture)
            shreg <= {selected_digest, done};
        else if (bscan_sel && bscan_shift)
            shreg <= {bscan_tdi, shreg[256:1]};
    end

    // A completed DR scan leaves its TDI payload in shreg. Commit the low
    // selector bits during Update-DR so they choose the following capture.
    always @(posedge bscan_tck) begin
        if (bscan_sel && bscan_update)
            read_sel <= shreg[SEL_W-1:0];
    end

    assign bscan_tdo = shreg[0];

endmodule
