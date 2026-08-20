`timescale 1ns/1ps

// Standard 8N1 UART transmitter with valid/ready handshake.
//
//   Frame: 1 start bit (low), 8 data bits (LSB first), 1 stop bit (high).
//   No parity, no flow control.
//
// Interface:
//   tx_data  [7:0]  : byte to send. Captured when tx_valid && tx_ready.
//   tx_valid        : producer asserts when tx_data is valid.
//   tx_ready        : this module asserts when it can accept a new byte
//                     (i.e. currently idle). Handshake: producer must hold
//                     tx_valid until tx_ready is seen high on the same edge.
//   tx_serial       : UART line out. Idle high.
//
// CLKS_PER_BIT is derived from CLK_HZ/BAUD; the default (125 MHz / 115200)
// gives 1085 clock cycles per bit (~0.16% baud error, well within tolerance).

module uart_tx #(
    parameter integer CLK_HZ = 125_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst,

    input  wire [7:0] tx_data,
    input  wire       tx_valid,
    output wire       tx_ready,

    output reg        tx_serial
);
    localparam integer CLKS_PER_BIT = CLK_HZ / BAUD;

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]  state = S_IDLE;
    reg [15:0] tick  = 16'd0;   // enough for CLKS_PER_BIT up to ~65535
    reg [2:0]  bit_idx = 3'd0;
    reg [7:0]  shifter = 8'd0;

    assign tx_ready = (state == S_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            tick      <= 16'd0;
            bit_idx   <= 3'd0;
            shifter   <= 8'd0;
            tx_serial <= 1'b1;      // idle high
        end else begin
            case (state)
                S_IDLE: begin
                    tx_serial <= 1'b1;
                    tick      <= 16'd0;
                    bit_idx   <= 3'd0;
                    if (tx_valid) begin
                        shifter <= tx_data;
                        state   <= S_START;
                    end
                end

                S_START: begin
                    tx_serial <= 1'b0;               // start bit
                    if (tick == CLKS_PER_BIT - 1) begin
                        tick  <= 16'd0;
                        state <= S_DATA;
                    end else begin
                        tick <= tick + 16'd1;
                    end
                end

                S_DATA: begin
                    tx_serial <= shifter[bit_idx];   // LSB first
                    if (tick == CLKS_PER_BIT - 1) begin
                        tick <= 16'd0;
                        if (bit_idx == 3'd7) begin
                            state <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 3'd1;
                        end
                    end else begin
                        tick <= tick + 16'd1;
                    end
                end

                S_STOP: begin
                    tx_serial <= 1'b1;               // stop bit
                    if (tick == CLKS_PER_BIT - 1) begin
                        tick  <= 16'd0;
                        state <= S_IDLE;
                    end else begin
                        tick <= tick + 16'd1;
                    end
                end
            endcase
        end
    end

endmodule
