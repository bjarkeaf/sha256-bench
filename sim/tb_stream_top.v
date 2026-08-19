`timescale 1ns/1ps

// Testbench for sha256_stream_top.
//
// Runs the 64-stream, 100-packet-per-stream chaining scheme end to end and
// prints per-stream final digests plus the XOR root, in the same format as
// sim/ref_stream.py so the two logs can be diffed.

module tb_stream_top;

    localparam PERIOD = 10; // ns
    reg clk = 0;
    always #(PERIOD/2) clk = ~clk;

    reg rst = 1;

    wire         done;
    wire [255:0] root_digest;
    wire [64*256-1:0] stream_digests_flat;

    sha256_stream_top uut (
        .clk                 (clk),
        .rst                 (rst),
        .done                (done),
        .root_digest         (root_digest),
        .stream_digests_flat (stream_digests_flat)
    );

    // Safety timeout: 6400 blocks + 64 latency + reset headroom + margin
    localparam integer TIMEOUT = 8000;
    integer cyc_cnt = 0;
    always @(posedge clk) if (!rst) cyc_cnt <= cyc_cnt + 1;

    integer i;
    reg [255:0] sd;

    initial begin
        rst = 1;
        repeat (4) @(posedge clk);
        rst = 0;

        // Wait for done, with timeout
        while (!done && cyc_cnt < TIMEOUT) @(posedge clk);
        // Sample one delta after the rising edge to let non-blocking assigns settle
        #1;

        if (!done) begin
            $display("FAIL: timeout at cyc_cnt=%0d without done", cyc_cnt);
            $finish;
        end

        for (i = 0; i < 64; i = i + 1) begin
            sd = stream_digests_flat[i*256 +: 256];
            $display("STREAM %02d = %064h", i, sd);
        end
        $display("ROOT      = %064h", root_digest);

        $finish;
    end

endmodule
