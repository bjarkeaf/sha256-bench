`timescale 1ns/1ps

// Time-multiplexed SHA-256 chaining pipeline (single core).
//
// Implements Peter's BOTEC scheme (../peter-sha256-botec.md), scaled down to
// one pipelined core:
//
//   - NSTREAMS=64 independent hash chains, round-robined through a fully-
//     pipelined SHA-256 compression core (LOOP=1, 64-cycle latency).
//   - Each stream chains PACKETS_PER_STREAM=100 blocks; final digest per
//     stream = H after 100 blocks.
//   - After all blocks are processed, output ROOT = XOR-reduce of the 64 stream
//     digests. (Placeholder for the "one more SHA core combines them" step in
//     the BOTEC. XOR is enough to exercise the pipeline; it can be replaced
//     later with a real SHA-256 tree without changing the scheduler.)
//
// Chaining is done *externally* to sha256_transform: we read the last
// digester's registered state via tx_state_final, add the per-stream rx_state
// ourselves, write the result back to the state RAM, and forward it as the
// next block's rx_state. Because the pipeline is exactly 64 cycles deep and
// we have exactly 64 streams round-robining, the writeback slot for stream i
// always coincides with the read slot for stream i's next block.
//
// Input blocks come from 8 parallel 64-bit Fibonacci LFSRs, forming a single
// deterministic 512-bit-per-cycle sequence. The Python reference
// (sim/ref_stream.py) mirrors this exactly.

module sha256_stream_top (
    input  wire         clk,
    input  wire         rst,

    // Asserted for one cycle when the root digest is valid, then held.
    output reg          done,
    output reg  [255:0] root_digest,

    // Flat concatenation of the 64 stream digests, stream 0 at bits[255:0],
    // stream 63 at bits[64*256-1:63*256]. Valid alongside `done`.
    output wire [64*256-1:0] stream_digests_flat
);
    localparam integer NSTREAMS           = 64;
    localparam integer PACKETS_PER_STREAM = 100;
    localparam integer TOTAL_BLOCKS       = NSTREAMS * PACKETS_PER_STREAM; // 6400
    localparam integer LATENCY            = 64;                            // fully-unrolled SHA-256
    localparam integer DRAIN_END          = TOTAL_BLOCKS + LATENCY;        // 6464

    // SHA-256 initial hash values, packed {h,g,f,e,d,c,b,a} with a at bits[31:0].
    localparam [255:0] SHA256_IV = {
        32'h5be0cd19, 32'h1f83d9ab, 32'h9b05688c, 32'h510e527f,
        32'ha54ff53a, 32'h3c6ef372, 32'hbb67ae85, 32'h6a09e667
    };

    // -----------------------------------------------------------------------
    // Global cycle counter (also drives round-robin stream id)
    // -----------------------------------------------------------------------
    reg [15:0] cyc;
    always @(posedge clk) begin
        if (rst)                    cyc <= 16'd0;
        else if (cyc < DRAIN_END)   cyc <= cyc + 16'd1;
    end

    // Round-robin stream id: at cycle T, stream_id = T mod 64.
    // Because LATENCY == NSTREAMS, the block exiting the pipeline at cycle T
    // belongs to the same stream as the block entering at cycle T.
    wire [5:0] sid = cyc[5:0];

    // Pipeline output valid = we've been running long enough for the first
    // block to have propagated end-to-end.
    wire pipe_valid = (cyc >= LATENCY);

    // -----------------------------------------------------------------------
    // PRNG: 8 independent 64-bit Fibonacci LFSRs
    //   poly x^64 + x^63 + x^61 + x^60 + 1, shift-left, feedback into LSB.
    //   Distinct non-zero seeds; Python reference must match bit-for-bit.
    // -----------------------------------------------------------------------
    reg [63:0] lfsr [0:7];
    integer li;
    always @(posedge clk) begin
        if (rst) begin
            lfsr[0] <= 64'h0123456789abcdef;
            lfsr[1] <= 64'hfedcba9876543210;
            lfsr[2] <= 64'hdeadbeefcafebabe;
            lfsr[3] <= 64'hbadc0ffee0ddf00d;
            lfsr[4] <= 64'h5a5a5a5aa5a5a5a5;
            lfsr[5] <= 64'h1234567890abcdef;
            lfsr[6] <= 64'hf00dfacef00dface;
            lfsr[7] <= 64'h13579bdf2468ace0;
        end else begin
            for (li = 0; li < 8; li = li + 1)
                lfsr[li] <= {lfsr[li][62:0],
                             lfsr[li][63] ^ lfsr[li][62] ^ lfsr[li][60] ^ lfsr[li][59]};
        end
    end

    // 512-bit block: lane 0 in bits[63:0], lane 7 in bits[511:448].
    wire [511:0] prng_block = {lfsr[7], lfsr[6], lfsr[5], lfsr[4],
                                lfsr[3], lfsr[2], lfsr[1], lfsr[0]};

    // -----------------------------------------------------------------------
    // Per-stream state RAM (64 x 256 bits), initialised to IV on reset.
    // -----------------------------------------------------------------------
    reg [255:0] state_ram [0:63];
    integer si;

    // Combinational reads/updates.
    // old_H: the running hash for the current stream, as of its previous block.
    //        Because no writes to state_ram[sid] occur in the 63 cycles between
    //        stream sid's turns, this is the same value that was written at
    //        the last visit.
    wire [255:0] old_H = state_ram[sid];
    wire [255:0] tx_state_final;

    // SHA-256 finalisation: H_new = H_old + last_digester_state (per-word +).
    // When pipe_valid is false (first 64 cycles), the pipeline hasn't produced
    // its first output yet, so we pass old_H through unchanged.
    wire [255:0] new_H;
    genvar w;
    generate
        for (w = 0; w < 8; w = w + 1) begin : ADD
            assign new_H[w*32 +: 32] = pipe_valid
                ? old_H[w*32 +: 32] + tx_state_final[w*32 +: 32]
                : old_H[w*32 +: 32];
        end
    endgenerate

    // Writeback: at end of cycle T, stream_id T mod 64's slot gets new_H,
    // which is the freshly-finalised hash of that stream's most recent block.
    // Simultaneously, new_H is forwarded to the pipeline as rx_state for the
    // block entering this same cycle (stream sid's next block).
    always @(posedge clk) begin
        if (rst) begin
            for (si = 0; si < 64; si = si + 1)
                state_ram[si] <= SHA256_IV;
        end else if (cyc < DRAIN_END) begin
            state_ram[sid] <= new_H;
        end
    end

    // -----------------------------------------------------------------------
    // SHA-256 compression core (fully pipelined, 64 cycles)
    // -----------------------------------------------------------------------
    wire [255:0] tx_hash_unused;
    sha256_transform #(.LOOP(1)) core (
        .clk            (clk),
        .feedback       (1'b0),
        .cnt            (6'd0),
        .rx_state       (new_H),         // forward: block entering at T gets its stream's fresh H
        .rx_input       (prng_block),
        .tx_hash        (tx_hash_unused),
        .tx_state_final (tx_state_final) // combinational tap on last digester's registered state
    );

    // -----------------------------------------------------------------------
    // Closeout
    // -----------------------------------------------------------------------
    // At cyc = DRAIN_END, the writeback for the very last block (T = 6399)
    // has just landed in state_ram[63]. All 64 slots now hold final digests.
    integer ri;
    reg [255:0] root_comb;
    always @* begin
        root_comb = 256'd0;
        for (ri = 0; ri < 64; ri = ri + 1)
            root_comb = root_comb ^ state_ram[ri];
    end

    always @(posedge clk) begin
        if (rst) begin
            done        <= 1'b0;
            root_digest <= 256'd0;
        end else if (cyc >= DRAIN_END) begin
            done        <= 1'b1;
            root_digest <= root_comb;
        end
    end

    // Expose per-stream digests as a flat bus.
    genvar sd;
    generate
        for (sd = 0; sd < 64; sd = sd + 1) begin : DIGEST_OUT
            assign stream_digests_flat[sd*256 +: 256] = state_ram[sd];
        end
    endgenerate

endmodule
