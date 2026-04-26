// =============================================================================
// fpga_top_board_demo.sv
//
// Board-demo wrapper for MurmurHash3 on the Nexys A7-100T.
//
// This wrapper is intentionally separate from fpga_top.sv so the evaluation
// flow can keep its original 100 MHz setup, while the board demo uses a safer
// 50 MHz core clock derived from the onboard 100 MHz oscillator.
//
// Notes
// -----
// 1. This demonstrates that the accelerator can be instantiated and run on the
//    FPGA board.
// 2. It is not a hardware correctness checker. The LEDs show a visible
//    heartbeat plus live hash activity.
// 3. The board demo uses a simple /2 fabric divider to make timing closure
//    easier for the accelerator demonstration.
// =============================================================================

module fpga_top_board_demo #(
    parameter int N     = 4,
    parameter int TAG_W = 1
) (
    input  logic        clk,    // 100 MHz board oscillator
    input  logic        rst_n,  // active-low reset pushbutton
    output logic [15:0] led
);

    // -------------------------------------------------------------------------
    // Derive a 50 MHz core clock for a more timing-safe board demo.
    // -------------------------------------------------------------------------
    logic core_clk;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            core_clk <= 1'b0;
        else
            core_clk <= ~core_clk;
    end

    // -------------------------------------------------------------------------
    // Counters
    // -------------------------------------------------------------------------
    logic [31:0] key_counter;
    logic [25:0] blink_counter;

    always_ff @(posedge core_clk or negedge rst_n) begin
        if (!rst_n) begin
            key_counter   <= '0;
            blink_counter <= '0;
        end else begin
            key_counter   <= key_counter + 1'b1;
            blink_counter <= blink_counter + 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Accelerator port wires
    // -------------------------------------------------------------------------
    logic [N-1:0]            valid_in;
    logic [N-1:0][127:0]     key_in;
    logic [N-1:0][31:0]      seed_in;
    logic [N-1:0][TAG_W-1:0] tag_in;

    logic [N-1:0]            valid_out;
    logic [N-1:0][31:0]      hash_out;
    logic [N-1:0][TAG_W-1:0] tag_out;

    // -------------------------------------------------------------------------
    // Debug signals for Vivado ILA insertion.
    // Keep lane 0 input visibility for reference, and expose all four lane
    // outputs so the board demo clearly shows that multiple lanes are active.
    // -------------------------------------------------------------------------
    (* mark_debug = "true" *) logic         dbg_core_clk;
    (* mark_debug = "true" *) logic [31:0]  dbg_key_counter;
    (* mark_debug = "true" *) logic         dbg_lane0_valid_in;
    (* mark_debug = "true" *) logic [127:0] dbg_lane0_key;
    (* mark_debug = "true" *) logic [31:0]  dbg_lane0_seed;
    (* mark_debug = "true" *) logic         dbg_lane0_valid_out;
    (* mark_debug = "true" *) logic [31:0]  dbg_lane0_hash;
    (* mark_debug = "true" *) logic         dbg_lane1_valid_out;
    (* mark_debug = "true" *) logic [31:0]  dbg_lane1_hash;
    (* mark_debug = "true" *) logic         dbg_lane2_valid_out;
    (* mark_debug = "true" *) logic [31:0]  dbg_lane2_hash;
    (* mark_debug = "true" *) logic         dbg_lane3_valid_out;
    (* mark_debug = "true" *) logic [31:0]  dbg_lane3_hash;
    (* mark_debug = "true" *) logic [15:0]  dbg_led;

    always_comb begin
        for (int i = 0; i < N; i++) begin
            valid_in[i] = 1'b1;
            key_in[i]   = {4{key_counter + 32'(i)}};
            seed_in[i]  = 32'hDEAD_BEEF;
            tag_in[i]   = TAG_W'(i);
        end
    end

    murmurhash3_accel #(
        .N     (N),
        .TAG_W (TAG_W)
    ) u_accel (
        .clk       (core_clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .key_in    (key_in),
        .seed_in   (seed_in),
        .tag_in    (tag_in),
        .valid_out (valid_out),
        .hash_out  (hash_out),
        .tag_out   (tag_out)
    );

    // -------------------------------------------------------------------------
    // LED mapping
    //   led[15]   : visible heartbeat so the board obviously looks alive
    //   led[14:0] : low hash bits XORed across all valid lanes
    // -------------------------------------------------------------------------
    logic [15:0] hash_xor;
    always_comb begin
        hash_xor = '0;
        for (int i = 0; i < N; i++) begin
            if (valid_out[i])
                hash_xor ^= hash_out[i][15:0];
        end
    end

    assign led[15]   = blink_counter[25];
    assign led[14:0] = hash_xor[14:0];

    assign dbg_core_clk        = core_clk;
    assign dbg_key_counter     = key_counter;
    assign dbg_lane0_valid_in  = valid_in[0];
    assign dbg_lane0_key       = key_in[0];
    assign dbg_lane0_seed      = seed_in[0];
    assign dbg_lane0_valid_out = valid_out[0];
    assign dbg_lane0_hash      = hash_out[0];

    if (N > 1) begin : g_dbg_lane1
        assign dbg_lane1_valid_out = valid_out[1];
        assign dbg_lane1_hash      = hash_out[1];
    end else begin : g_dbg_lane1_zero
        assign dbg_lane1_valid_out = 1'b0;
        assign dbg_lane1_hash      = '0;
    end

    if (N > 2) begin : g_dbg_lane2
        assign dbg_lane2_valid_out = valid_out[2];
        assign dbg_lane2_hash      = hash_out[2];
    end else begin : g_dbg_lane2_zero
        assign dbg_lane2_valid_out = 1'b0;
        assign dbg_lane2_hash      = '0;
    end

    if (N > 3) begin : g_dbg_lane3
        assign dbg_lane3_valid_out = valid_out[3];
        assign dbg_lane3_hash      = hash_out[3];
    end else begin : g_dbg_lane3_zero
        assign dbg_lane3_valid_out = 1'b0;
        assign dbg_lane3_hash      = '0;
    end

    assign dbg_led = led;

endmodule
