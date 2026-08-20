`timescale 1ns/1ps

// Board-level UART wrapper for sha256_stream_top targeting the Pynq-Z2.
//
// Runs the streaming SHA-256 scheduler once at power-on, then streams the
// per-stream digests and the XOR root out on a PMOD UART line in the same
// format as sim/tb_stream_top.v and sim/ref_stream.py, so a laptop-side
// script can diff them directly.
//
// Format (per line, terminated by \r\n):
//   "STREAM 00 = <64 hex>"
//   "STREAM 01 = <64 hex>"
//   ...
//   "STREAM <NSTREAMS-1> = <64 hex>"
//   "ROOT      = <64 hex>"
//
// Parameter LOOP is set by synth/uart.tcl per bitstream, so a single set of
// RTL sources produces the whole sweep. NSTREAMS = 64/LOOP is derived.
//
// LEDs (Pynq-Z2 LD0..LD1):
//   LD0 led_alive  : ~1 Hz heartbeat off the 125 MHz clock (board-is-up
//                    indicator, independent of the DUT completing).
//   LD1 led_done   : mirrors sha256_stream_top.done (high after the run).
//
// Reset is self-generated so no board button is required: rst is held high
// for the first 128 cycles after configuration, then released.

module sha256_stream_uart_top #(
    parameter integer LOOP = 1
) (
    input  wire clk,           // 125 MHz onboard oscillator (Pynq-Z2 H16)
    output wire uart_tx_pin,   // PMOD JA1
    output wire led_alive,     // LD0
    output wire led_done       // LD1
);
    localparam integer NSTREAMS = 64 / LOOP;
    // Line format constants
    localparam integer PREFIX_LEN = 12;                                   // "STREAM XX = " or "ROOT      = "
    localparam integer HEX_LEN    = 64;
    localparam integer TAIL_LEN   = 2;                                    // \r\n
    localparam integer LINE_LEN   = PREFIX_LEN + HEX_LEN + TAIL_LEN;      // 78

    // -----------------------------------------------------------------------
    // Self-clearing reset
    // -----------------------------------------------------------------------
    reg [7:0] rst_cnt = 8'd0;
    wire rst = ~rst_cnt[7];
    always @(posedge clk)
        if (!rst_cnt[7]) rst_cnt <= rst_cnt + 8'd1;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    wire         done;
    wire [255:0] root_digest;
    wire [NSTREAMS*256-1:0] stream_digests_flat;

    sha256_stream_top #(.LOOP(LOOP)) uut (
        .clk                 (clk),
        .rst                 (rst),
        .done                (done),
        .root_digest         (root_digest),
        .stream_digests_flat (stream_digests_flat)
    );

    // -----------------------------------------------------------------------
    // Byte-serialiser: walks record_idx from 0..NSTREAMS (root at NSTREAMS),
    // and byte_pos from 0..LINE_LEN-1 within each record.
    // -----------------------------------------------------------------------
    localparam integer RIDX_W = $clog2(NSTREAMS + 2);   // enough for 0..NSTREAMS
    localparam integer BPOS_W = 7;                       // fits LINE_LEN=78

    reg [RIDX_W-1:0] record_idx = {RIDX_W{1'b0}};
    reg [BPOS_W-1:0] byte_pos   = {BPOS_W{1'b0}};
    reg              finished   = 1'b0;

    wire is_root_record = (record_idx == NSTREAMS);

    // Truncate record_idx to a NSTREAMS-in-range index for the state-RAM
    // part-select. When is_root_record is true the value is a don't-care
    // because the outer mux picks root_digest; the truncation just prevents
    // an out-of-range +: select on the flat bus.
    localparam integer SID_W_LOCAL = (NSTREAMS <= 1) ? 1 : $clog2(NSTREAMS);
    wire [SID_W_LOCAL-1:0] sram_idx = record_idx[SID_W_LOCAL-1:0];

    // Digest currently being emitted. Wide mux (up to 64 x 256 bits) but
    // record_idx only changes on line boundaries, so this settles for the
    // 78 UART bytes worth of time it takes to send the current line.
    wire [255:0] current_digest;
    assign current_digest = is_root_record
        ? root_digest
        : stream_digests_flat[sram_idx*256 +: 256];

    // Prefix character generator. Uses byte_pos as a table index.
    // Two-digit stream number: tens and ones digits of record_idx.
    wire [3:0] tens = record_idx / 5'd10;
    wire [3:0] ones = record_idx - (tens * 5'd10);

    reg [7:0] prefix_char;
    always @* begin
        case (byte_pos[3:0])
            4'd0:  prefix_char = is_root_record ? "R" : "S";
            4'd1:  prefix_char = is_root_record ? "O" : "T";
            4'd2:  prefix_char = is_root_record ? "O" : "R";
            4'd3:  prefix_char = is_root_record ? "T" : "E";
            4'd4:  prefix_char = is_root_record ? " " : "A";
            4'd5:  prefix_char = is_root_record ? " " : "M";
            4'd6:  prefix_char =                                          " ";
            4'd7:  prefix_char = is_root_record ? " " : (8'h30 + {4'd0, tens});
            4'd8:  prefix_char = is_root_record ? " " : (8'h30 + {4'd0, ones});
            4'd9:  prefix_char =                                          " ";
            4'd10: prefix_char =                                          "=";
            4'd11: prefix_char =                                          " ";
            default: prefix_char = " ";
        endcase
    end

    // Hex nibble generator: byte_pos in [PREFIX_LEN, PREFIX_LEN+HEX_LEN-1].
    // MSB nibble first: byte_pos=12 -> nibble 63, byte_pos=75 -> nibble 0.
    wire [6:0] nibble_idx_full = 7'd75 - byte_pos;
    wire [5:0] nibble_idx      = nibble_idx_full[5:0];
    wire [3:0] nibble          = current_digest[nibble_idx*4 +: 4];
    wire [7:0] hex_char        = (nibble < 4'd10)
                                    ? (8'h30 + {4'd0, nibble})            // '0'..'9'
                                    : (8'h61 + {4'd0, nibble - 4'd10});   // 'a'..'f'

    reg [7:0] byte_out;
    always @* begin
        if (byte_pos < PREFIX_LEN)                 byte_out = prefix_char;
        else if (byte_pos < PREFIX_LEN + HEX_LEN)  byte_out = hex_char;
        else if (byte_pos == LINE_LEN - 2)         byte_out = 8'h0D;      // \r
        else                                       byte_out = 8'h0A;      // \n
    end

    // -----------------------------------------------------------------------
    // UART instance + handshake
    // -----------------------------------------------------------------------
    wire uart_ready;
    wire byte_valid    = done & ~finished;
    wire byte_accepted = byte_valid & uart_ready;

    always @(posedge clk) begin
        if (rst) begin
            record_idx <= {RIDX_W{1'b0}};
            byte_pos   <= {BPOS_W{1'b0}};
            finished   <= 1'b0;
        end else if (byte_accepted) begin
            if (byte_pos == LINE_LEN - 1) begin
                byte_pos <= {BPOS_W{1'b0}};
                if (is_root_record) finished <= 1'b1;
                else                record_idx <= record_idx + 1'b1;
            end else begin
                byte_pos <= byte_pos + 1'b1;
            end
        end
    end

    uart_tx #(.CLK_HZ(125_000_000), .BAUD(115_200)) tx (
        .clk       (clk),
        .rst       (rst),
        .tx_data   (byte_out),
        .tx_valid  (byte_valid),
        .tx_ready  (uart_ready),
        .tx_serial (uart_tx_pin)
    );

    // -----------------------------------------------------------------------
    // LEDs
    // -----------------------------------------------------------------------
    reg [26:0] hb = 27'd0;
    always @(posedge clk) hb <= hb + 27'd1;

    assign led_alive = hb[26];
    assign led_done  = done;

endmodule
