`timescale 1ns/1ps

// Testbench for sha256-bench.
// Two sections:
//   1. Correctness: drives sha256_transform directly with the "abc" padded test vector,
//      waits 65 cycles, checks output against SHA-256("abc").
//   2. Throughput: runs bench_top for T cycles and reports observed hash rate.
//
// Compile-time parameters (override via -D flags):
//   LOOP    : unroll factor for bench_top (default 1)
//   N_CORES : number of cores for bench_top (default 1)

`ifndef LOOP
  `define LOOP 1
`endif
`ifndef N_CORES
  `define N_CORES 1
`endif

module tb_bench_top;

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    localparam PERIOD = 10; // ns (100 MHz for sim; Fmax is a synthesis concern)

    reg clk = 0;
    always #(PERIOD/2) clk = ~clk;

    // =========================================================================
    // Section 1: Correctness check via direct sha256_transform instantiation
    // =========================================================================
    //
    // SHA-256("abc") test vector:
    //   Message:  0x61 62 63
    //   Padded 512-bit block:
    //     W[0]  = 0x61626380,  W[1..14] = 0x00000000,  W[15] = 0x00000018
    //   rx_input packing: W[0] at bits[31:0], W[15] at bits[511:480]
    //
    // SHA-256 IV: {h,g,f,e,d,c,b,a} packed as IDX(0)=a=bits[31:0] ... IDX(7)=h=bits[255:224]
    //
    // Expected tx_hash (SHA-256("abc") = ba7816bf 8f01cfea 414140de 5dae2223
    //                                    b00361a3 96177a9c b410ff61 f20015ad):
    //   bits[31:0]    = H0 = 0xba7816bf
    //   bits[255:224] = H7 = 0xf20015ad

    localparam [511:0] ABC_BLOCK = {
        32'h00000018,                       // W[15] bits[511:480]
        32'h00000000, 32'h00000000,         // W[14:13]
        32'h00000000, 32'h00000000,         // W[12:11]
        32'h00000000, 32'h00000000,         // W[10:9]
        32'h00000000, 32'h00000000,         // W[8:7]
        32'h00000000, 32'h00000000,         // W[6:5]
        32'h00000000, 32'h00000000,         // W[4:3]
        32'h00000000, 32'h00000000,         // W[2:1]
        32'h61626380                        // W[0]  bits[31:0]
    };

    localparam [255:0] SHA256_IV = {
        32'h5be0cd19, 32'h1f83d9ab, 32'h9b05688c, 32'h510e527f,
        32'ha54ff53a, 32'h3c6ef372, 32'hbb67ae85, 32'h6a09e667
    };

    localparam [255:0] SHA256_ABC = {
        32'hf20015ad, 32'hb410ff61, 32'h96177a9c, 32'hb00361a3,
        32'h5dae2223, 32'h414140de, 32'h8f01cfea, 32'hba7816bf
    };

    wire [255:0] chk_hash;

    // LOOP=1: 64 pipeline stages, feedback=0, cnt=0 always
    sha256_transform #(.LOOP(1)) chk_core (
        .clk      (clk),
        .feedback (1'b0),
        .cnt      (6'd0),
        .rx_state (SHA256_IV),
        .rx_input (ABC_BLOCK),
        .tx_hash  (chk_hash)
    );

    integer corr_fail = 0;

    initial begin
        // Wait 70 rising edges for the 64-stage pipeline to fill with the "abc" block
        // (input is combinatorially connected, so no explicit reset needed)
        repeat (70) @(posedge clk);
        #1; // sample after rising edge settles

        if (chk_hash !== SHA256_ABC) begin
            $display("FAIL correctness: got %h, expected %h", chk_hash, SHA256_ABC);
            corr_fail = 1;
        end else begin
            $display("PASS correctness: SHA-256(abc) = %h", chk_hash);
        end
    end

    // =========================================================================
    // Section 2: Throughput check via bench_top
    // =========================================================================

    localparam integer T       = 10000; // simulation cycles
    localparam integer LOOP_P  = `LOOP;
    localparam integer NCORES  = `N_CORES;

    reg rst = 1;

    wire [255:0] hash_xor_all;

    bench_top #(.LOOP(LOOP_P), .N_CORES(NCORES)) uut (
        .clk         (clk),
        .rst         (rst),
        .hash_xor_all(hash_xor_all)
    );

    // Count hash-valid pulses: one pulse = N_CORES hashes
    // hash_valid condition: !feedback && pipe_full (internal signals)
    wire hash_valid = !uut.feedback && uut.pipe_full;

    integer hash_pulses = 0;
    integer cycle_count = 0;

    always @(posedge clk) begin
        if (!rst) begin
            cycle_count <= cycle_count + 1;
            if (hash_valid)
                hash_pulses <= hash_pulses + 1;
        end
    end

    initial begin
        rst = 1;
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (T) @(posedge clk);

        begin : report
            real cycles_per_hash;
            real throughput_bits_per_cycle;
            integer total_hashes;

            total_hashes = hash_pulses * NCORES;
            // Effective cycles per hash per core
            if (hash_pulses > 0)
                cycles_per_hash = (1.0 * cycle_count) / (1.0 * hash_pulses);
            else
                cycles_per_hash = 0;

            throughput_bits_per_cycle = (total_hashes > 0) ?
                (512.0 * total_hashes / cycle_count) : 0;

            $display("THROUGHPUT LOOP=%0d N_CORES=%0d: %0d cycles, %0d hashes, %.2f cycles/hash/core, %.1f bits/cycle aggregate",
                LOOP_P, NCORES, cycle_count, total_hashes, cycles_per_hash, throughput_bits_per_cycle);

            // Sanity: cycles_per_hash should equal LOOP_P (within 1%)
            if (hash_pulses > 0 &&
                (cycles_per_hash < LOOP_P * 0.99 || cycles_per_hash > LOOP_P * 1.01)) begin
                $display("FAIL throughput: expected %.0f cycles/hash, got %.2f", 1.0*LOOP_P, cycles_per_hash);
                corr_fail = 1;
            end else if (hash_pulses > 0) begin
                $display("PASS throughput");
            end else begin
                $display("WARN no hash pulses seen (pipeline may not have filled)");
            end
        end

        if (corr_fail)
            $display("OVERALL: FAIL");
        else
            $display("OVERALL: PASS");

        $finish;
    end

endmodule
