`timescale 1ns/1ps

// Time-multiplexed SHA-256 chaining pipeline (single core), parametric on LOOP.
//
// Implements Peter's BOTEC scheme (../peter-sha256-botec.md), scaled down to
// one pipelined core with the same LOOP knob as bench_top:
//
//   - LOOP ∈ {1, 2, 4, 8, 16, 32} (must divide 64 evenly). Sets the unroll
//     factor of the SHA-256 core: 64/LOOP stages, each block passes through
//     the pipeline LOOP times via the internal `feedback` path. Throughput
//     is 1 block per LOOP cycles; latency stays 64 cycles for any LOOP.
//   - NSTREAMS = 64/LOOP independent hash chains, round-robined through the
//     core. Chosen so that the round-robin invariant NSTREAMS × LOOP = 64
//     holds — a block written back for stream `sid` at cycle T aligns with
//     that same stream's next block entering at cycle T.
//   - Each stream chains BLOCKS_PER_STREAM=100 blocks; final digest per
//     stream = H after 100 blocks. Runtime is TOTAL_BLOCKS×LOOP = 6400
//     cycles regardless of LOOP.
//   - After all blocks are processed, output ROOT = XOR-reduce of the
//     NSTREAMS stream digests. Placeholder for the "one more SHA core
//     combines them" step in the BOTEC.
//
// Chaining is done *externally* to sha256_transform via the tx_state_final
// tap (the last digester stage's registered output), skipping the +1 cycle
// tx_hash output register. External chain-add: new_H = old_H + tx_state_final
// with per-stream old_H read from state_ram.
//
// Input blocks come from 8 parallel 64-bit Fibonacci LFSRs. The LFSR
// advances only on block-entry cycles (cnt==0), so the block sequence is
// identical to the Python reference regardless of LOOP.

module sha256_stream_top #(
    parameter integer LOOP = 1
) (
    input  wire         clk,
    input  wire         rst,

    // Asserted for one cycle when the root digest is valid, then held.
    output reg          done,
    output reg  [255:0] root_digest,

    // Flat concatenation of the NSTREAMS stream digests, stream 0 at
    // bits[255:0], stream (NSTREAMS-1) at bits[NSTREAMS*256-1 : (NSTREAMS-1)*256].
    // Valid alongside `done`.
    output wire [(64/LOOP)*256-1:0] stream_digests_flat
);
    localparam integer NSTREAMS          = 64 / LOOP;
    localparam integer BLOCKS_PER_STREAM = 100;
    localparam integer TOTAL_BLOCKS      = NSTREAMS * BLOCKS_PER_STREAM;
    localparam integer LATENCY           = 64;                                // pipeline latency, LOOP-invariant
    localparam integer DRAIN_END         = TOTAL_BLOCKS * LOOP + LATENCY;     // = 6464 for all legal LOOP
    localparam integer SID_W             = (NSTREAMS <= 1) ? 1 : $clog2(NSTREAMS);
    localparam integer CNT_W             = (LOOP     <= 1) ? 1 : $clog2(LOOP);

    // SHA-256 initial hash values, packed {h,g,f,e,d,c,b,a} with a at bits[31:0].
    localparam [255:0] SHA256_IV = {
        32'h5be0cd19, 32'h1f83d9ab, 32'h9b05688c, 32'h510e527f,
        32'ha54ff53a, 32'h3c6ef372, 32'hbb67ae85, 32'h6a09e667
    };

    // -----------------------------------------------------------------------
    // Global cycle counter
    // -----------------------------------------------------------------------
    reg [15:0] cyc;
    always @(posedge clk) begin
        if (rst)                  cyc <= 16'd0;
        else if (cyc < DRAIN_END) cyc <= cyc + 16'd1;
    end

    // -----------------------------------------------------------------------
    // Sub-block counter (cnt) and round-robin stream id (sid)
    //
    // Total slot index = cyc mod (LATENCY = NSTREAMS * LOOP):
    //   cnt = cyc mod LOOP        — 0 on block-entry cycles, 1..LOOP-1 on feedback cycles
    //   sid = (cyc / LOOP) mod NSTREAMS
    // Both are bit-slices because NSTREAMS and LOOP are powers of 2.
    //
    // Three special cases (see the localparam guards above for the width
    // fallback that kicks in when a computed index would be zero):
    //   NSTREAMS == 1 (LOOP=64) — sid is always 0; cnt cycles 0..63.
    //   LOOP     == 1           — cnt is always 0; sid cycles 0..63.
    //   otherwise               — both cycle.
    // -----------------------------------------------------------------------
    wire [5:0]         cnt;
    wire [SID_W-1:0]   sid;
    wire               cnt_zero;
    generate
        if (NSTREAMS == 1) begin : G_NS1
            assign cnt      = {{(6-CNT_W){1'b0}}, cyc[CNT_W-1:0]};
            assign sid      = {SID_W{1'b0}};
            assign cnt_zero = (cyc[CNT_W-1:0] == {CNT_W{1'b0}});
        end else if (LOOP == 1) begin : G_LOOP1
            assign cnt      = 6'd0;
            assign sid      = cyc[SID_W-1:0];
            assign cnt_zero = 1'b1;
        end else begin : G_LOOPN
            assign cnt      = {{(6-CNT_W){1'b0}}, cyc[CNT_W-1:0]};
            assign sid      = cyc[SID_W+CNT_W-1 : CNT_W];
            assign cnt_zero = (cyc[CNT_W-1:0] == {CNT_W{1'b0}});
        end
    endgenerate

    // Pipeline output valid = we've been running long enough for the first
    // block to have propagated end-to-end. LATENCY=64 for any LOOP.
    wire pipe_valid = (cyc >= LATENCY);

    // sha256_transform's `feedback` input: high on cnt!=0 cycles.
    wire feedback = ~cnt_zero;

    // -----------------------------------------------------------------------
    // PRNG: 8 independent 64-bit Fibonacci LFSRs
    //   poly x^64 + x^63 + x^61 + x^60 + 1, shift-left, feedback into LSB.
    //   Distinct non-zero seeds; Python reference must match bit-for-bit.
    // LFSR advances only on block-entry cycles (cnt==0) so the block
    // sequence is independent of LOOP.
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
        end else if (cnt_zero) begin
            for (li = 0; li < 8; li = li + 1)
                lfsr[li] <= {lfsr[li][62:0],
                             lfsr[li][63] ^ lfsr[li][62] ^ lfsr[li][60] ^ lfsr[li][59]};
        end
    end

    // 512-bit block: lane 0 in bits[63:0], lane 7 in bits[511:448].
    wire [511:0] prng_block = {lfsr[7], lfsr[6], lfsr[5], lfsr[4],
                                lfsr[3], lfsr[2], lfsr[1], lfsr[0]};

    // -----------------------------------------------------------------------
    // Per-stream state RAM (NSTREAMS x 256 bits), initialised to IV on reset.
    // -----------------------------------------------------------------------
    reg [255:0] state_ram [0:NSTREAMS-1];
    integer si;

    wire [255:0] old_H = state_ram[sid];
    wire [255:0] tx_state_final;

    // SHA-256 finalisation: H_new = H_old + last_digester_state (per-word +).
    // When pipe_valid is false (first 64 cycles), the pipeline hasn't produced
    // its first output yet, so we pass old_H through unchanged. new_H is only
    // consumed on cnt==0 cycles anyway.
    wire [255:0] new_H;
    genvar w;
    generate
        for (w = 0; w < 8; w = w + 1) begin : ADD
            assign new_H[w*32 +: 32] = pipe_valid
                ? old_H[w*32 +: 32] + tx_state_final[w*32 +: 32]
                : old_H[w*32 +: 32];
        end
    endgenerate

    // Writeback: only on block-entry cycles (cnt==0), before drain end.
    // tx_state_final is only a valid finalised digest on cnt==0; on cnt>0
    // it's mid-loop self-feedback data, so writing then would corrupt.
    always @(posedge clk) begin
        if (rst) begin
            for (si = 0; si < NSTREAMS; si = si + 1)
                state_ram[si] <= SHA256_IV;
        end else if (cnt_zero && cyc < DRAIN_END) begin
            state_ram[sid] <= new_H;
        end
    end

    // -----------------------------------------------------------------------
    // SHA-256 compression core (LOOP-way unrolled)
    // -----------------------------------------------------------------------
    wire [255:0] tx_hash_unused;
    sha256_transform #(.LOOP(LOOP)) core (
        .clk            (clk),
        .feedback       (feedback),
        .cnt            (cnt),
        .rx_state       (new_H),          // forward: block entering at cnt=0 gets its stream's fresh H
        .rx_input       (prng_block),
        .tx_hash        (tx_hash_unused),
        .tx_state_final (tx_state_final)  // combinational tap on last digester's registered state
    );

    // -----------------------------------------------------------------------
    // Closeout: XOR-reduce root over NSTREAMS stream digests.
    // -----------------------------------------------------------------------
    integer ri;
    reg [255:0] root_comb;
    always @* begin
        root_comb = 256'd0;
        for (ri = 0; ri < NSTREAMS; ri = ri + 1)
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
        for (sd = 0; sd < NSTREAMS; sd = sd + 1) begin : DIGEST_OUT
            assign stream_digests_flat[sd*256 +: 256] = state_ram[sd];
        end
    endgenerate

endmodule
