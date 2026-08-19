`timescale 1ns/1ps

// Parametric SHA-256 benchmark top.
// LOOP   : unroll factor (1=fully pipelined 64-stage, 2=32-stage 2-cycle, ..., 32=2-stage 32-cycle)
// N_CORES: number of independent SHA-256 pipelines
//
// All cores share one cnt/feedback clock-enable so they step in lockstep.
// Each core has its own 64-bit LFSR to supply independent 512-bit input blocks,
// preventing synthesis from constant-folding the pipeline.
//
// hash_xor_all: running XOR of all core outputs, written once per hash batch.
// Provides a live output root that prevents synthesis from pruning the pipeline.

module bench_top #(
    parameter integer LOOP    = 1,
    parameter integer N_CORES = 1
) (
    input  wire        clk,
    input  wire        rst,
    output reg  [255:0] hash_xor_all
);

    // SHA-256 initial hash values (IV), packed as {h, g, f, e, d, c, b, a}
    // IDX(0)=bits[31:0]=a, IDX(7)=bits[255:224]=h
    localparam [255:0] SHA256_IV = {
        32'h5be0cd19, 32'h1f83d9ab, 32'h9b05688c, 32'h510e527f,
        32'ha54ff53a, 32'h3c6ef372, 32'hbb67ae85, 32'h6a09e667
    };

    // Shared scheduling: one cnt/feedback drives all cores in lockstep
    reg  [5:0]  cnt;
    wire        feedback = (LOOP == 1) ? 1'b0 : (cnt != 6'd0);

    always @(posedge clk)
        if (rst) cnt <= 6'd0;
        else     cnt <= (cnt == LOOP - 1) ? 6'd0 : cnt + 6'd1;

    // Pipeline fill tracker: hash outputs are valid after 64 clock cycles
    reg  [6:0]  fill_ctr;
    wire        pipe_full = fill_ctr[6];

    always @(posedge clk)
        if (rst) fill_ctr <= 7'd0;
        else if (!pipe_full) fill_ctr <= fill_ctr + 7'd1;

    // Per-core hash outputs collected into a flat bus
    wire [N_CORES*256-1:0] all_hashes;

    genvar g;
    generate
    for (g = 0; g < N_CORES; g = g + 1) begin : CORES

        // 64-bit Fibonacci LFSR (poly x^64+x^63+x^61+x^60+1), unique seed per core
        reg [63:0] lfsr;

        always @(posedge clk) begin
            if (rst)
                lfsr <= 64'hba5eba11deadbeef ^ {32'd0, g + 1};
            else
                lfsr <= {lfsr[62:0], lfsr[63] ^ lfsr[62] ^ lfsr[60] ^ lfsr[59]};
        end

        wire [255:0] tx_hash;

        sha256_transform #(.LOOP(LOOP)) core_inst (
            .clk      (clk),
            .feedback (feedback),
            .cnt      (cnt),
            .rx_state (SHA256_IV),
            .rx_input ({8{lfsr}}),
            .tx_hash  (tx_hash)
        );

        assign all_hashes[g*256 +: 256] = tx_hash;

    end
    endgenerate

    // XOR-reduce all core outputs (combinational)
    integer k;
    reg [255:0] xor_reduce;
    always @(*) begin
        xor_reduce = 256'd0;
        for (k = 0; k < N_CORES; k = k + 1)
            xor_reduce = xor_reduce ^ all_hashes[k*256 +: 256];
    end

    // Register the XOR output once per hash batch (prevents synthesis pruning)
    always @(posedge clk)
        if (rst)
            hash_xor_all <= 256'd0;
        else if (!feedback && pipe_full)
            hash_xor_all <= hash_xor_all ^ xor_reduce;

endmodule
