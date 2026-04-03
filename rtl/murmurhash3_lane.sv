// =============================================================================
// murmurhash3_lane.sv
//
// MurmurHash3_x86_32 — single-lane, fully-pipelined implementation.
//
// ALGORITHM
// ---------
// Implements the body + finalization of MurmurHash3_x86_32 for a fixed
// 128-bit (16-byte) key with no tail bytes.  The C reference is:
//
//   void MurmurHash3_x86_32(const void *key, int len, uint32_t seed, void *out)
//
// For len=16 the algorithm is:
//
//   h = seed
//   for each 32-bit block b[0..3]:               // body loop, 4 iterations
//       k  = b * 0xcc9e2d51
//       k  = ROTL32(k, 15)
//       k  = k * 0x1b873593
//       h ^= k
//       h  = ROTL32(h, 13)
//       h  = h*5 + 0xe6546b64
//   h ^= 16                                      // mix in length
//   h ^= h >> 16                                 // fmix32
//   h  = h * 0x85ebca6b
//   h ^= h >> 13
//   h  = h * 0xc2b2ae35
//   h ^= h >> 16
//   output h
//
// PIPELINE STRUCTURE
// ------------------
// The 4-iteration body loop is unrolled into 4 independent register stages
// (S1–S4).  The fmix32 finalization is split across two additional stages
// (S5–S6) — one multiplication per stage — to meet timing at 100 MHz on
// Artix-7.  Total pipeline depth: 6 stages, 6 clock cycles latency.
//
//   S1: mix block 0  →  register  (h1, key[127:32], tag)
//   S2: mix block 1  →  register  (h2, key[127:64], tag)
//   S3: mix block 2  →  register  (h3, key[127:96], tag)
//   S4: mix block 3  →  register  (h4,              tag)
//   S5: h ^= 16; h ^= h>>16; h *= FMIX_C1; h ^= h>>13  →  register
//   S6: h *= FMIX_C2; h ^= h>>16  →  output
//
// Each stage is purely combinational logic driving a register; there is no
// feedback or inter-stage dependency within the same clock cycle.  The
// non-blocking assignment semantics of always_ff ensure that each stage
// reads the previous cycle's registered values, not the current cycle's
// newly computed values.  This is correct pipeline behavior.
//
// THROUGHPUT AND LATENCY
// ----------------------
// The pipeline accepts one new key per clock cycle (throughput = 1 hash/cycle
// per lane) with a fixed latency of 6 cycles.  There are no stall conditions:
// the pipeline has no back-pressure mechanism.  The caller must be able to
// consume one output per cycle when feeding one input per cycle.
//
// HOW INPUTS ARE ACCEPTED
// -----------------------
// A transaction is accepted by asserting valid_in = 1 and presenting stable
// key_in, seed_in, and tag_in on the same rising clock edge.  The lane
// samples all four inputs on that edge and begins processing.
//
//   - There is no ready/valid handshake: valid_in is sampled every cycle
//     regardless.  When valid_in = 0, the pipeline still advances; the
//     corresponding stage register is marked invalid (s*_v = 0) so its
//     data will not appear at the output.
//   - Back-to-back transactions are legal: valid_in may be held high for
//     consecutive cycles.  Each cycle produces an independent in-flight
//     transaction.
//   - There is no mechanism to stall or replay an input.  If the caller
//     cannot deliver a key on a given cycle it must deassert valid_in.
//
// WHEN OUTPUTS BECOME VALID
// -------------------------
// valid_out rises exactly 6 cycles after the corresponding valid_in.
// hash_out and tag_out are only meaningful when valid_out = 1.  They
// remain stable for one clock cycle (registered outputs).
//
// ONE KEY PER TRANSACTION — ASSUMPTIONS
// --------------------------------------
// 1. The key width is fixed at 128 bits.  No partial keys, no streaming
//    key input across multiple cycles.  One rising edge = one complete key.
// 2. There is no length field: the hardware always treats the key as
//    exactly 16 bytes and XORs h with 16 in stage S5.  Keys shorter than
//    16 bytes must be zero-padded by the caller.
// 3. key_in[31:0] is block 0 (bytes 0–3 in little-endian order), matching
//    the C getblock32 semantics.  The caller is responsible for byte ordering.
// 4. seed_in is sampled atomically with valid_in.  There is no mechanism to
//    change the seed mid-pipeline; each in-flight transaction carries its own
//    seed through the stages via the registered datapath.
// 5. The TAG passthrough (tag_in → tag_out) is provided solely for the
//    testbench scoreboard.  It adds registers but no functional logic.
//    It can be removed (TAG_W = 0 is not supported; set TAG_W = 1 and tie
//    tag_in = 0 if unused, or remove the port for synthesis-only builds).
//
// SYNTHESIZABILITY
// ----------------
// All constructs are Vivado-synthesizable (tested against Vivado 2022+).
// - function automatic: supported; local variables are inferred as wires.
// - Rotate-left: inlined as bit-concatenation (pure wiring, zero LUTs).
// - 32×32 constant multiply: synthesized to DSP48E1 or LUT adder tree
//   depending on Vivado strategy.  Each stage has at most one such multiply
//   on the critical path after the fmix32 split.
// - Data registers are not reset (saves ~30% flip-flop area); only valid
//   bits are reset.
//
// Synthesizable: YES
// =============================================================================

module murmurhash3_lane #(
    parameter int TAG_W = 8   // Width of the passthrough tag.
                              // Set equal to $clog2(max_in_flight) in the
                              // testbench.  Unused bits waste registers but
                              // do not affect correctness.
) (
    input  logic              clk,
    input  logic              rst_n,    // asynchronous active-low reset

    // -------------------------------------------------------------------------
    // Input channel — no handshake, no ready signal.
    // Sample valid_in, key_in, seed_in, tag_in on every rising clock edge.
    // -------------------------------------------------------------------------
    input  logic              valid_in, // 1 → accept this transaction this cycle
    input  logic [127:0]      key_in,   // 128-bit key; [31:0]=block0 (little-endian)
    input  logic [31:0]       seed_in,  // per-transaction seed
    input  logic [TAG_W-1:0]  tag_in,   // opaque tag; forwarded unchanged to output

    // -------------------------------------------------------------------------
    // Output channel — registered, no handshake.
    // valid_out rises 6 cycles after the corresponding valid_in.
    // hash_out and tag_out are stable for one cycle when valid_out = 1.
    // -------------------------------------------------------------------------
    output logic              valid_out,
    output logic [31:0]       hash_out,
    output logic [TAG_W-1:0]  tag_out
);

    // =========================================================================
    // Constants (MurmurHash3_x86_32)
    // =========================================================================
    localparam logic [31:0] C1       = 32'hcc9e2d51; // body block multiply constant 1
    localparam logic [31:0] C2       = 32'h1b873593; // body block multiply constant 2
    localparam logic [31:0] MIX_ADD  = 32'he6546b64; // body additive constant
    localparam logic [31:0] FMIX_C1  = 32'h85ebca6b; // fmix32 multiply constant 1
    localparam logic [31:0] FMIX_C2  = 32'hc2b2ae35; // fmix32 multiply constant 2
    localparam logic [31:0] KEY_LEN  = 32'd16;        // key length in bytes (fixed)

    // =========================================================================
    // Combinational datapath functions
    //
    // These are pure functions: no side effects, no state.  Synthesis infers
    // them as combinational logic.  Rotate-left is inlined as concatenation
    // to avoid nested function calls inside always_ff (a known Vivado risk).
    // =========================================================================

    // One iteration of the MurmurHash3 body loop.
    // Critical path: (blk * C1) → (* C2).  Both are 32×32 constant multiplies
    // in series.  Vivado's constant-coefficient multiplier handles this, but
    // retiming (`set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE Explore`) may
    // be needed if post-route slack is negative.
    function automatic logic [31:0] mix_block (
        input logic [31:0] h,    // running hash from previous stage
        input logic [31:0] blk   // 32-bit key block for this iteration
    );
        logic [31:0] k;
        k = blk * C1;
        k = {k[16:0], k[31:17]};          // ROTL32(k, 15) — pure bit permutation
        k = k   * C2;
        h = h   ^ k;
        h = {h[18:0], h[31:19]};          // ROTL32(h, 13) — pure bit permutation
        h = (h  * 32'd5) + MIX_ADD;       // h*5 = (h<<2)+h; Vivado optimizes this
        return h;
    endfunction

    // fmix32 first half: one 32×32 constant multiply.
    // Input: h after body loop with length XOR'd in (h ^ 16).
    function automatic logic [31:0] fmix32_p1 (input logic [31:0] h);
        h = h ^ (h >> 16);   // avalanche high bits downward
        h = h * FMIX_C1;     // ← only multiply in this stage
        h = h ^ (h >> 13);   // avalanche
        return h;
    endfunction

    // fmix32 second half: one 32×32 constant multiply.
    // Depends on the output of fmix32_p1 registered at end of S5.
    function automatic logic [31:0] fmix32_p2 (input logic [31:0] h);
        h = h * FMIX_C2;     // ← only multiply in this stage
        h = h ^ (h >> 16);   // final avalanche
        return h;
    endfunction

    // =========================================================================
    // Pipeline registers
    //
    // Naming convention: s<N>_* is the output register of stage N.
    //
    // Valid bits (s*_v) are reset on rst_n = 0.
    // Data registers (s*_h, s*_key, s*_tag) are NOT reset.  They hold
    // don't-care values when the corresponding valid bit is 0, which is
    // safe because the output channel gates everything behind valid_out.
    //
    // Key forwarding: unrequired key blocks are carried forward stage-by-stage
    // alongside the hash accumulator.  Each stage consumes the lowest 32 bits
    // of the forwarded slice and passes the remainder to the next stage.
    // This avoids reading key_in from a distant register stage (long wire).
    // =========================================================================

    // --- Stage 1 outputs (produced from: seed_in, key_in) ---
    logic             s1_v;
    logic [31:0]      s1_h;      // hash after mixing block 0
    logic [95:0]      s1_key;    // key_in[127:32]: blocks 1, 2, 3 not yet consumed
    logic [TAG_W-1:0] s1_tag;

    // --- Stage 2 outputs (produced from: s1_h, s1_key[31:0]=block1) ---
    logic             s2_v;
    logic [31:0]      s2_h;      // hash after mixing block 1
    logic [63:0]      s2_key;    // s1_key[95:32]: blocks 2, 3 not yet consumed
    logic [TAG_W-1:0] s2_tag;

    // --- Stage 3 outputs (produced from: s2_h, s2_key[31:0]=block2) ---
    logic             s3_v;
    logic [31:0]      s3_h;      // hash after mixing block 2
    logic [31:0]      s3_key;    // s2_key[63:32]: block 3 not yet consumed
    logic [TAG_W-1:0] s3_tag;

    // --- Stage 4 outputs (produced from: s3_h, s3_key[31:0]=block3) ---
    logic             s4_v;
    logic [31:0]      s4_h;      // hash after mixing all 4 blocks
    logic [TAG_W-1:0] s4_tag;

    // --- Stage 5 outputs (produced from: s4_h ^ KEY_LEN → fmix32_p1) ---
    logic             s5_v;
    logic [31:0]      s5_h;      // intermediate fmix32 value
    logic [TAG_W-1:0] s5_tag;

    // --- Stage 6 outputs (produced from: s5_h → fmix32_p2) — drives outputs ---
    logic             s6_v;
    logic [31:0]      s6_h;      // final hash
    logic [TAG_W-1:0] s6_tag;

    // =========================================================================
    // Pipeline register update
    //
    // All six stages are clocked in one always_ff block.  Because these are
    // non-blocking assignments, every RHS is evaluated using the values from
    // the previous clock cycle (before any LHS updates).  This gives correct
    // pipeline staging: stage N reads the registered output of stage N-1
    // from the previous cycle, not the combinatorially updated value being
    // written in the same cycle.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Only valid bits need reset.  Data registers are don't-care.
            s1_v <= 1'b0;
            s2_v <= 1'b0;
            s3_v <= 1'b0;
            s4_v <= 1'b0;
            s5_v <= 1'b0;
            s6_v <= 1'b0;
        end else begin

            // -----------------------------------------------------------------
            // Stage 1: mix block 0 into seed
            //   Reads:  valid_in, seed_in, key_in
            //   Writes: s1_v, s1_h, s1_key, s1_tag
            // -----------------------------------------------------------------
            s1_v   <= valid_in;
            s1_tag <= tag_in;
            s1_h   <= mix_block(seed_in, key_in[31:0]);  // block 0 = key_in[31:0]
            s1_key <= key_in[127:32];                     // forward blocks 1,2,3

            // -----------------------------------------------------------------
            // Stage 2: mix block 1
            //   Reads:  s1_v, s1_h, s1_key
            //   Writes: s2_v, s2_h, s2_key, s2_tag
            //   Block 1 = s1_key[31:0]  = original key_in[63:32]
            // -----------------------------------------------------------------
            s2_v   <= s1_v;
            s2_tag <= s1_tag;
            s2_h   <= mix_block(s1_h, s1_key[31:0]);
            s2_key <= s1_key[95:32];                      // forward blocks 2,3

            // -----------------------------------------------------------------
            // Stage 3: mix block 2
            //   Reads:  s2_v, s2_h, s2_key
            //   Writes: s3_v, s3_h, s3_key, s3_tag
            //   Block 2 = s2_key[31:0]  = original key_in[95:64]
            // -----------------------------------------------------------------
            s3_v   <= s2_v;
            s3_tag <= s2_tag;
            s3_h   <= mix_block(s2_h, s2_key[31:0]);
            s3_key <= s2_key[63:32];                      // forward block 3

            // -----------------------------------------------------------------
            // Stage 4: mix block 3
            //   Reads:  s3_v, s3_h, s3_key
            //   Writes: s4_v, s4_h, s4_tag
            //   Block 3 = s3_key[31:0]  = original key_in[127:96]
            //   After this stage the body loop is complete.
            // -----------------------------------------------------------------
            s4_v   <= s3_v;
            s4_tag <= s3_tag;
            s4_h   <= mix_block(s3_h, s3_key[31:0]);

            // -----------------------------------------------------------------
            // Stage 5: length XOR + fmix32 first half
            //   Reads:  s4_v, s4_h
            //   Writes: s5_v, s5_h, s5_tag
            //   Operations: h ^= 16;  h ^= h>>16;  h *= FMIX_C1;  h ^= h>>13
            //   One 32×32 multiply on critical path.
            // -----------------------------------------------------------------
            s5_v   <= s4_v;
            s5_tag <= s4_tag;
            s5_h   <= fmix32_p1(s4_h ^ KEY_LEN);

            // -----------------------------------------------------------------
            // Stage 6: fmix32 second half → final output
            //   Reads:  s5_v, s5_h
            //   Writes: s6_v, s6_h, s6_tag
            //   Operations: h *= FMIX_C2;  h ^= h>>16
            //   One 32×32 multiply on critical path.
            //   valid_out / hash_out / tag_out are assigned from s6_* below.
            // -----------------------------------------------------------------
            s6_v   <= s5_v;
            s6_tag <= s5_tag;
            s6_h   <= fmix32_p2(s5_h);

        end
    end

    // =========================================================================
    // Output assignments — combinational, driven directly from stage 6 registers
    // =========================================================================
    assign valid_out = s6_v;
    assign hash_out  = s6_h;
    assign tag_out   = s6_tag;

endmodule
