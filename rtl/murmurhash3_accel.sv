// =============================================================================
// murmurhash3_accel.sv
//
// Parameterized N-lane MurmurHash3_x86_32 accelerator.
//
// STRUCTURE
// ---------
// This module is a structural wrapper.  It instantiates N independent copies
// of murmurhash3_lane and connects them in parallel.  There is no shared
// state, no arbitration logic, and no inter-lane communication.
//
// THROUGHPUT SCALING
// ------------------
// Each lane accepts one key per clock cycle.  With N lanes operating in
// parallel, the accelerator can sustain N hashes per clock cycle once all
// pipelines are filled (after the 6-cycle initial latency).
//
//   Sustained throughput : N hashes / cycle
//   Latency per hash     : 6 cycles (independent of N)
//
// This is the motivation for the scaling study: doubling N doubles throughput
// at the cost of doubling area, with no impact on latency or clock frequency.
//
// HOW INPUTS ARE ACCEPTED
// -----------------------
// Each lane has its own valid_in[i], key_in[i], seed_in[i], and tag_in[i].
// Lanes are fully independent: valid_in is per-lane.  Two common usage modes:
//
//   Mode A — Parallel batch:
//     Assert all N valid_in bits on the same cycle.  All N lanes receive a
//     different key simultaneously.  After 6 cycles, all N hash_out values
//     are valid simultaneously.
//
//   Mode B — Round-robin:
//     Assert valid_in[cycle % N] each cycle, rotating across lanes.
//     This achieves 1 hash/cycle throughput with N=1 equivalent hardware
//     but is useful when the input source can only produce one key per cycle.
//     In this mode, N=6 is the minimum to keep the pipeline full without
//     gaps (latency = 6 cycles = pipeline depth).
//
// The caller is responsible for routing keys to lanes and collecting results.
// This module does not include a dispatcher or output collector.
//
// WHEN OUTPUTS BECOME VALID
// -------------------------
// valid_out[i] rises 6 cycles after valid_in[i] was asserted for lane i.
// Each lane's output is independent.  In Mode A, all N valid_out bits rise
// together.  In Mode B, valid_out[i] rises on cycle (i + 6) % N.
//
// OUTPUT ORDERING
// ---------------
// There is no global output ordering guarantee.  Outputs arrive in-order
// within a single lane (the pipeline is stall-free), but there is no
// ordering relationship between different lanes.
//
// If the caller needs to reconstruct the original input order across lanes,
// the tag_in passthrough should carry a sequence number.  tag_out will then
// carry the same number at the output, allowing the caller to reorder results.
//
// PARAMETERIZATION
// ----------------
// N is the sole scaling parameter.  To run the Vivado scaling study:
//   - Elaborate murmurhash3_accel with N = 1, 2, 4, 8
//   - Collect utilization_N*.rpt and power_N*.rpt from reports/
//   - Expected: area scales linearly; Fmax is approximately constant
//     (no shared critical path across lanes)
//
// TAG_W should match the testbench scoreboard width.  For synthesis-only
// builds (no testbench), TAG_W can be set to 1 with tag_in tied to 0.
//
// ONE KEY PER TRANSACTION — ASSUMPTIONS (inherited from murmurhash3_lane)
// -------------------------------------------------------------------------
// 1. Each valid_in assertion carries exactly one complete 128-bit key.
//    There is no multi-cycle key streaming.
// 2. Keys shorter than 128 bits must be zero-padded by the caller.
// 3. key_in[i][31:0] = block 0 of lane i's key (little-endian byte order).
// 4. seed_in[i] is sampled atomically with valid_in[i].
//
// Synthesizable: YES
// =============================================================================

module murmurhash3_accel #(
    parameter int N     = 4,   // number of parallel lanes; sweep for scaling study
    parameter int TAG_W = 8    // passthrough tag width; see murmurhash3_lane.sv
) (
    input  logic                        clk,
    input  logic                        rst_n,   // asynchronous active-low reset

    // -------------------------------------------------------------------------
    // Per-lane input arrays.
    // Packed 2-D: outer index [N-1:0] selects the lane.
    // Vivado synthesizes packed multi-dimensional logic arrays correctly.
    // -------------------------------------------------------------------------
    input  logic [N-1:0]                valid_in,
    input  logic [N-1:0][127:0]         key_in,
    input  logic [N-1:0][31:0]          seed_in,
    input  logic [N-1:0][TAG_W-1:0]     tag_in,

    // -------------------------------------------------------------------------
    // Per-lane output arrays.
    // valid_out[i] rises 6 cycles after valid_in[i] was asserted.
    // hash_out[i] and tag_out[i] are valid when valid_out[i] = 1.
    // -------------------------------------------------------------------------
    output logic [N-1:0]                valid_out,
    output logic [N-1:0][31:0]          hash_out,
    output logic [N-1:0][TAG_W-1:0]     tag_out
);

    // =========================================================================
    // Lane instantiation
    //
    // Each lane is independent.  No logic exists between lanes at this level.
    // Vivado will place each lane's registers as a group; expect roughly linear
    // LUT/FF scaling with N.
    // =========================================================================
    generate
        for (genvar i = 0; i < N; i++) begin : g_lanes
            murmurhash3_lane #(
                .TAG_W (TAG_W)
            ) u_lane (
                .clk       (clk),
                .rst_n     (rst_n),
                .valid_in  (valid_in[i]),
                .key_in    (key_in[i]),
                .seed_in   (seed_in[i]),
                .tag_in    (tag_in[i]),
                .valid_out (valid_out[i]),
                .hash_out  (hash_out[i]),
                .tag_out   (tag_out[i])
            );
        end
    endgenerate

endmodule
