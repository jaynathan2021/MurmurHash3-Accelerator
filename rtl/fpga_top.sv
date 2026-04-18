// =============================================================================
// fpga_top.sv
//
// FPGA top-level wrapper for MurmurHash3 accelerator on Nexys A4.
//
// Exposes only clk, rst_n, and 16 LEDs so the design fits within the
// 210 usable I/O pins of the xc7a100tcsg324-1.
//
// A free-running 32-bit counter drives sequential keys into all N lanes.
// The XOR of all hash outputs is displayed on the LEDs, preventing Vivado
// from optimizing away the datapath during implementation.
// =============================================================================

module fpga_top #(
    parameter int N     = 4,
    parameter int TAG_W = 1
) (
    input  logic        clk,
    input  logic        rst_n,
    output logic [15:0] led       // LEDs show XOR of all hash outputs
);

    // -------------------------------------------------------------------------
    // Counter — drives unique keys into each lane every cycle
    // -------------------------------------------------------------------------
    logic [31:0] counter;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) counter <= '0;
        else        counter <= counter + 1'b1;
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

    // Drive all lanes with counter-derived keys — one unique key per lane
    always_comb begin
        for (int i = 0; i < N; i++) begin
            valid_in[i] = 1'b1;
            key_in[i]   = {4{counter + 32'(i)}};  // 128-bit key from counter
            seed_in[i]  = 32'hDEAD_BEEF;
            tag_in[i]   = TAG_W'(i);
        end
    end

    // -------------------------------------------------------------------------
    // Accelerator instance
    // -------------------------------------------------------------------------
    murmurhash3_accel #(
        .N     (N),
        .TAG_W (TAG_W)
    ) u_accel (
        .clk       (clk),
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
    // XOR all hash outputs to LEDs — keeps the datapath alive through P&R
    // -------------------------------------------------------------------------
    logic [31:0] hash_xor;
    always_comb begin
        hash_xor = '0;
        for (int i = 0; i < N; i++)
            hash_xor ^= hash_out[i];
    end

    assign led = hash_xor[15:0];

endmodule
