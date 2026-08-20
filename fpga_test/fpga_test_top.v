`timescale 1ns / 1ps

module fpga_test_top (
    input  wire sysclk,
    input  wire sw0,
    output wire led_pass,
    output wire led_heartbeat,
    output wire led_loaded
);

    // ------------------------------------------------------------
    // Clock generation
    // ------------------------------------------------------------

    wire clk50;
    wire locked;

    `ifdef SIMULATION

        // For ordinary Verilog simulation we don't need to model
        // the physical Xilinx clock hardware.
        assign clk50  = sysclk;
        assign locked = 1'b1;

    `else

        // Physical FPGA: 125 MHz -> 50 MHz using the Zynq MMCM.

        wire clkfb_raw;
        wire clkfb;
        wire clk50_raw;

        MMCME2_BASE #(
            .CLKIN1_PERIOD(8.0),
            .CLKFBOUT_MULT_F(8.0),
            .DIVCLK_DIVIDE(1),
            .CLKOUT0_DIVIDE_F(20.0)
        ) mmcm (
            .CLKIN1(sysclk),
            .CLKFBIN(clkfb),
            .CLKFBOUT(clkfb_raw),
            .CLKOUT0(clk50_raw),
            .LOCKED(locked),
            .PWRDWN(1'b0),
            .RST(1'b0)
        );

        BUFG fb_buf (
            .I(clkfb_raw),
            .O(clkfb)
        );

        BUFG clk_buf (
            .I(clk50_raw),
            .O(clk50)
        );

    `endif


    // ------------------------------------------------------------
    // SHA-256("abc") test vector.
    // Same packing used by tb_bench_top.v.
    // ------------------------------------------------------------

    localparam [511:0] ABC_BLOCK = {
        32'h00000018,
        32'h00000000, 32'h00000000,
        32'h00000000, 32'h00000000,
        32'h00000000, 32'h00000000,
        32'h00000000, 32'h00000000,
        32'h00000000, 32'h00000000,
        32'h00000000, 32'h00000000,
        32'h00000000, 32'h00000000,
        32'h61626380
    };

    localparam [255:0] SHA256_IV = {
        32'h5be0cd19,
        32'h1f83d9ab,
        32'h9b05688c,
        32'h510e527f,
        32'ha54ff53a,
        32'h3c6ef372,
        32'hbb67ae85,
        32'h6a09e667
    };

    localparam [255:0] SHA256_ABC = {
        32'hf20015ad,
        32'hb410ff61,
        32'h96177a9c,
        32'hb00361a3,
        32'h5dae2223,
        32'h414140de,
        32'h8f01cfea,
        32'hba7816bf
    };


    // ------------------------------------------------------------
    // Runtime-selectable input.
    //
    // SW0 = 0 -> "abc"
    // SW0 = 1 -> zeros
    //
    // Making the input depend on a physical switch prevents Vivado
    // from treating the SHA input as a compile-time constant.
    // ------------------------------------------------------------

    wire [511:0] sha_input =
        sw0 ? 512'd0 : ABC_BLOCK;



    // ------------------------------------------------------------
    // Loop general
    // ------------------------------------------------------------

    // LOOP=64 means one physical SHA round is reused for all 64 rounds.
    localparam integer SHA_LOOP = 1;

    reg [5:0] sha_cnt = 6'd0;

    // On cnt=0, load a new input/state.
    // On subsequent cycles, feed the previous round back into the core.
    wire sha_feedback =
        (SHA_LOOP == 1) ? 1'b0 : (sha_cnt != 6'd0);

    always @(posedge clk50) begin
        if (!locked)
            sha_cnt <= 6'd0;
        else if (sha_cnt == SHA_LOOP - 1)
            sha_cnt <= 6'd0;
        else
            sha_cnt <= sha_cnt + 6'd1;
    end;


    // ------------------------------------------------------------
    // SHA core
    // ------------------------------------------------------------

    wire [255:0] tx_hash;

    sha256_transform #(
        .LOOP(SHA_LOOP)
    ) sha (
        .clk      (clk50),
        .feedback (sha_feedback),
        .cnt      (sha_cnt),
        .rx_state (SHA256_IV),
        .rx_input (sha_input),
        .tx_hash  (tx_hash)
    );

    // ------------------------------------------------------------
    // LEDs
    // ------------------------------------------------------------

    // After the pipeline fills, this turns on iff the hash is correct.
    assign led_pass =
        locked && (tx_hash == SHA256_ABC);

    // Heartbeat: proves the physical board clock is running.
    reg [26:0] heartbeat = 27'd0;

    always @(posedge sysclk)
        heartbeat <= heartbeat + 1'b1;

    assign led_heartbeat = heartbeat[26];

    // Simply proves that this particular bitstream was programmed.
    assign led_loaded = 1'b1;

endmodule