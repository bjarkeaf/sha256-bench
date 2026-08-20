`timescale 1ns/1ps

// Testbench for sha256_stream_top.
//
// Runs the NSTREAMS-stream, BLOCKS_PER_STREAM-per-stream chaining scheme
// end to end and prints per-stream final digests plus the XOR root, in the
// same format as sim/ref_stream.py so the two logs can be diffed.
//
// Compile with -DLOOP=N (N ∈ {1,2,4,8,16,32}) to pick the unroll factor.
// Defaults to LOOP=1.

`ifndef LOOP
  `define LOOP 1
`endif

module tb_stream_top;

    localparam integer LOOP     = `LOOP;
    localparam integer NSTREAMS = 64 / LOOP;

    localparam PERIOD = 10; // ns
    reg clk = 0;
    always #(PERIOD/2) clk = ~clk;

    reg rst = 1;

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

    // Safety timeout scales with LOOP: TOTAL_BLOCKS*LOOP + LATENCY + margin.
    // Total runtime cycles = 6400 + 64 = 6464 for any LOOP; give plenty of margin.
    localparam integer TIMEOUT = 8000;
    integer cyc_cnt = 0;
    always @(posedge clk) if (!rst) cyc_cnt <= cyc_cnt + 1;

    integer i;
    reg [255:0] sd;

    initial begin
        rst = 1;
        repeat (4) @(posedge clk);
        rst = 0;

        while (!done && cyc_cnt < TIMEOUT) @(posedge clk);
        #1;

        if (!done) begin
            $display("FAIL: timeout at cyc_cnt=%0d without done (LOOP=%0d)", cyc_cnt, LOOP);
            $finish;
        end

        for (i = 0; i < NSTREAMS; i = i + 1) begin
            sd = stream_digests_flat[i*256 +: 256];
            $display("STREAM %02d = %064h", i, sd);
        end
        $display("ROOT      = %064h", root_digest);

        $finish;
    end

endmodule
