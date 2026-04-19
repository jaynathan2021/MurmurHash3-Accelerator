// =============================================================================
// murmurhash3_lane.sv
//
// MurmurHash3_x86_32 — single-lane, fully-pipelined implementation.
//
// PIPELINE STRUCTURE — 11 stages
// --------------------------------
// Each of the 4 body blocks is split into 2 sub-stages so that the first
// DSP multiply (*C1) feeds directly into a register with only zero-delay
// ROTL wiring between the DSP output and the flip-flop (PREG=1 usable).
//
//   Sub-A (s1,s3,s5,s7): s_k = ROTL(blk * C1, 15)     [DSP: PREG=1 usable]
//   Sub-B (s2,s4,s6,s8): h   = ROTL(h ^ (k*C2), 13)*5+ADD
//
// fmix32 is split into 3 stages so both constant multiplies feed directly
// into registers (PREG=1 usable):
//
//   s9 : s_h = ((h^len) ^ ((h^len)>>16)) * FMIX_C1    [DSP: PREG=1 usable]
//   s10: s_h = (h ^ (h>>13)) * FMIX_C2                [DSP: PREG=1 usable]
//   s11: s_h = h ^ (h>>16)                             [output register]
//
// Total latency: 11 cycles.  Throughput: 1 hash/cycle/lane.
// =============================================================================

module murmurhash3_lane #(
    parameter int TAG_W = 8
) (
    input  logic              clk,
    input  logic              rst_n,

    input  logic              valid_in,
    input  logic [127:0]      key_in,
    input  logic [31:0]       seed_in,
    input  logic [TAG_W-1:0]  tag_in,

    output logic              valid_out,
    output logic [31:0]       hash_out,
    output logic [TAG_W-1:0]  tag_out
);

    localparam logic [31:0] C1      = 32'hcc9e2d51;
    localparam logic [31:0] C2      = 32'h1b873593;
    localparam logic [31:0] MIX_ADD = 32'he6546b64;
    localparam logic [31:0] FMIX_C1 = 32'h85ebca6b;
    localparam logic [31:0] FMIX_C2 = 32'hc2b2ae35;
    localparam logic [31:0] KEY_LEN = 32'd16;

    // =========================================================================
    // Valid shift register — 11 bits, async reset
    // v[0] = s1 valid ... v[10] = s11 valid
    // =========================================================================
    logic [10:0] v;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) v <= '0;
        else        v <= {v[9:0], valid_in};
    end

    // =========================================================================
    // Pipeline data registers (no reset — don't-care when valid=0)
    // =========================================================================

    // s1: Sub-A block0 — k = ROTL(block0 * C1, 15)
    logic [31:0]      s1_k;
    logic [31:0]      s1_seed;   // h_prev for s2 (= seed_in)
    logic [95:0]      s1_key;    // blocks 1..3 forwarded
    logic [TAG_W-1:0] s1_tag;

    // s2: Sub-B block0 — h = ROTL(seed ^ (s1_k*C2), 13)*5+MIX_ADD
    logic [31:0]      s2_h;
    logic [95:0]      s2_key;    // blocks 1..3 forwarded
    logic [TAG_W-1:0] s2_tag;

    // s3: Sub-A block1 — k = ROTL(block1 * C1, 15)
    logic [31:0]      s3_k;
    logic [31:0]      s3_h;      // h_prev for s4 (= s2_h)
    logic [63:0]      s3_key;    // blocks 2..3 forwarded
    logic [TAG_W-1:0] s3_tag;

    // s4: Sub-B block1
    logic [31:0]      s4_h;
    logic [63:0]      s4_key;    // blocks 2..3 forwarded
    logic [TAG_W-1:0] s4_tag;

    // s5: Sub-A block2 — k = ROTL(block2 * C1, 15)
    logic [31:0]      s5_k;
    logic [31:0]      s5_h;      // h_prev for s6
    logic [31:0]      s5_key;    // block3 forwarded
    logic [TAG_W-1:0] s5_tag;

    // s6: Sub-B block2
    logic [31:0]      s6_h;
    logic [31:0]      s6_key;    // block3 forwarded
    logic [TAG_W-1:0] s6_tag;

    // s7: Sub-A block3 — k = ROTL(block3 * C1, 15)
    logic [31:0]      s7_k;
    logic [31:0]      s7_h;      // h_prev for s8
    logic [TAG_W-1:0] s7_tag;

    // s8: Sub-B block3 — body complete
    logic [31:0]      s8_h;
    logic [TAG_W-1:0] s8_tag;

    // s9: fmix step 1 — multiply output directly to register (PREG=1 usable)
    logic [31:0]      s9_h;
    logic [TAG_W-1:0] s9_tag;

    // s10: fmix step 2 — multiply output directly to register (PREG=1 usable)
    logic [31:0]      s10_h;
    logic [TAG_W-1:0] s10_tag;

    // s11: fmix step 3 — final XOR → output
    logic [31:0]      s11_h;
    logic [TAG_W-1:0] s11_tag;

    // =========================================================================
    // Combinational intermediates
    // Declared as continuous assigns so each multiply is synthesized once and
    // the DSP output can be recognised as feeding directly into a register.
    // =========================================================================

    // Sub-A: blk * C1 (one DSP per block; ROTL is pure wiring after the reg)
    logic [31:0] c_s1_mul, c_s3_mul, c_s5_mul, c_s7_mul;
    assign c_s1_mul = key_in[31:0]  * C1;
    assign c_s3_mul = s2_key[31:0]  * C1;   // block1 = s2_key[31:0]
    assign c_s5_mul = s4_key[31:0]  * C1;   // block2 = s4_key[31:0]
    assign c_s7_mul = s6_key        * C1;   // block3 = s6_key (32-bit)

    // Sub-B: k_a * C2 (DSP; post-multiply logic keeps path <10 ns on Artix-7)
    logic [31:0] c_kc2_b0, c_kc2_b1, c_kc2_b2, c_kc2_b3;
    assign c_kc2_b0 = s1_k * C2;
    assign c_kc2_b1 = s3_k * C2;
    assign c_kc2_b2 = s5_k * C2;
    assign c_kc2_b3 = s7_k * C2;

    // Sub-B: full mix — ROTL(h ^ k_c2, 13)*5 + MIX_ADD
    // *5 = (t<<2)+t is an adder tree, no DSP.
    function automatic logic [31:0] sub_b_mix(
        input logic [31:0] h, k_c2
    );
        logic [31:0] t;
        t = h ^ k_c2;
        t = {t[18:0], t[31:19]};           // ROTL(t, 13)
        return (t * 32'd5) + MIX_ADD;
    endfunction

    // Fmix pre-multiply logic
    logic [31:0] c_f9_tmp, c_f9_pre, c_f10_pre;
    assign c_f9_tmp  = s8_h ^ KEY_LEN;
    assign c_f9_pre  = c_f9_tmp ^ (c_f9_tmp >> 16);  // input to *FMIX_C1
    assign c_f10_pre = s9_h    ^ (s9_h    >> 13);     // input to *FMIX_C2

    // =========================================================================
    // Pipeline register update (data path, no reset)
    // All RHS expressions read pre-update values (non-blocking semantics).
    // =========================================================================
    always_ff @(posedge clk) begin

        // ---- Stage 1: Sub-A block0 ----
        // ROTL is absorbed into bit routing; DSP output → register directly.
        s1_k    <= {c_s1_mul[16:0], c_s1_mul[31:17]};  // ROTL(mul,15)
        s1_seed <= seed_in;
        s1_key  <= key_in[127:32];
        s1_tag  <= tag_in;

        // ---- Stage 2: Sub-B block0 ----
        s2_h    <= sub_b_mix(s1_seed, c_kc2_b0);
        s2_key  <= s1_key;
        s2_tag  <= s1_tag;

        // ---- Stage 3: Sub-A block1 ----
        s3_k    <= {c_s3_mul[16:0], c_s3_mul[31:17]};
        s3_h    <= s2_h;
        s3_key  <= s2_key[95:32];                       // blocks 2..3 (64 bits)
        s3_tag  <= s2_tag;

        // ---- Stage 4: Sub-B block1 ----
        s4_h    <= sub_b_mix(s3_h, c_kc2_b1);
        s4_key  <= s3_key;
        s4_tag  <= s3_tag;

        // ---- Stage 5: Sub-A block2 ----
        s5_k    <= {c_s5_mul[16:0], c_s5_mul[31:17]};
        s5_h    <= s4_h;
        s5_key  <= s4_key[63:32];                       // block3 (32 bits)
        s5_tag  <= s4_tag;

        // ---- Stage 6: Sub-B block2 ----
        s6_h    <= sub_b_mix(s5_h, c_kc2_b2);
        s6_key  <= s5_key;
        s6_tag  <= s5_tag;

        // ---- Stage 7: Sub-A block3 ----
        s7_k    <= {c_s7_mul[16:0], c_s7_mul[31:17]};
        s7_h    <= s6_h;
        s7_tag  <= s6_tag;

        // ---- Stage 8: Sub-B block3 (body complete) ----
        s8_h    <= sub_b_mix(s7_h, c_kc2_b3);
        s8_tag  <= s7_tag;

        // ---- Stage 9: fmix step 1 — DSP output → register (PREG=1) ----
        s9_h    <= c_f9_pre * FMIX_C1;
        s9_tag  <= s8_tag;

        // ---- Stage 10: fmix step 2 — DSP output → register (PREG=1) ----
        s10_h   <= c_f10_pre * FMIX_C2;
        s10_tag <= s9_tag;

        // ---- Stage 11: fmix step 3 — final XOR ----
        s11_h   <= s10_h ^ (s10_h >> 16);
        s11_tag <= s10_tag;
    end

    // =========================================================================
    // Output assignments
    // =========================================================================
    assign valid_out = v[10];
    assign hash_out  = s11_h;
    assign tag_out   = s11_tag;

endmodule
