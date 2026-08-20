`timescale 1ns/1ps

// Divide-by-2 clock generator using a toggle FF fed into a BUFG.
//
// Used by the board wrappers to drop the Pynq-Z2's 125 MHz onboard clock down
// to 62.5 MHz, which is comfortably under the observed Fmax of the streaming
// wrapper (~75 MHz). The BUFG puts the divided clock on a proper global clock
// network so all downstream logic sees the same edges.
//
// Companion XDC line (referencing the BUFG output pin) is required for STA to
// understand the divided clock:
//
//     create_generated_clock -name clk_div2 \
//         -source [get_ports clk]           \
//         -divide_by 2                      \
//         [get_pins <inst>/bufg_inst/O]

module clk_div2 (
    input  wire clk_in,
    output wire clk_out
);
    reg tog = 1'b0;
    always @(posedge clk_in) tog <= ~tog;

    // Route the divided signal onto a global clock buffer. Xilinx primitive.
    // No effect / not instantiated during Icarus simulation (the board
    // wrappers aren't sim'd directly; the sim testbench targets
    // sha256_stream_top with an ideal clock).
    BUFG bufg_inst (.I(tog), .O(clk_out));
endmodule
