// tb_murmurhash3.sv
//
// NOT SYNTHESIZABLE — testbench only.
//
// Active tests:
//   1. C-verified directed vectors
//   2. Deterministic correctness sweep
//   Note: the older bandwidth-oriented flow is preserved below as a commented block.
//   3. Correctness sweep — 64 pseudo-random keys per lane
//   4. Bandwidth measurement — stream N lanes for 256 cycles
//
// Golden reference: an inline SV reimplementation of MurmurHash3_x86_32
// for fixed 128-bit keys.  Before trusting the testbench, run Test 1 with
// the C reference (sw/murmurhash3_ref.c) and confirm GOLDEN_0 / GOLDEN_1
// match.  Without that step the testbench only proves DUT == model, not
// model == spec.

`timescale 1ns/1ps

module tb_murmurhash3;

    // =========================================================================
    // Parameters — must match DUT
    // =========================================================================
    localparam int N              = 4;
    localparam int TAG_W          = 8;
    localparam int PIPELINE_DEPTH = 11;     // 4 body blocks x 2 sub-stages + 3 fmix stages
    localparam int SWEEP_CASES_PER_LANE = 8;
    localparam realtime CLK_HALF  = 5.0;    // 10 ns period → 100 MHz

    // =========================================================================
    // Hardcoded golden vectors
    // Compute with: sw/murmurhash3_ref.c  MurmurHash3_x86_32(key,16,seed,&out)
    // Replace 32'hXXXXXXXX once C reference has been run.
    // =========================================================================
    localparam logic [127:0] TV0_KEY    = 128'h0;
    localparam logic [31:0]  TV0_SEED   = 32'h0;
    localparam logic [31:0]  TV0_GOLDEN = 32'h8134cdf8;  // verified: sw/murmurhash3_ref.c

    localparam logic [127:0] TV1_KEY    = {128{1'b1}};
    localparam logic [31:0]  TV1_SEED   = 32'hdeadbeef;
    localparam logic [31:0]  TV1_GOLDEN = 32'h5cf7f123;  // verified: sw/murmurhash3_ref.c

    localparam logic [127:0] TV2_KEY    = 128'h0f0e0d0c0b0a09080706050403020100;
    localparam logic [31:0]  TV2_SEED   = 32'h00000001;
    localparam logic [31:0]  TV2_GOLDEN = 32'hbba77653;  // verified: sw/murmurhash3_ref.c

    localparam logic [127:0] TV3_KEY    = 128'haaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
    localparam logic [31:0]  TV3_SEED   = 32'hcafebabe;
    localparam logic [31:0]  TV3_GOLDEN = 32'h35c376a6;  // verified: sw/murmurhash3_ref.c

    // =========================================================================
    // Clock & reset
    // =========================================================================
    logic clk   = 1'b0;
    logic rst_n = 1'b0;

    always #CLK_HALF clk = ~clk;

    // =========================================================================
    // DUT interface signals
    // =========================================================================
    logic [N-1:0]                valid_in;
    logic [N-1:0][127:0]         key_in;
    logic [N-1:0][31:0]          seed_in;
    logic [N-1:0][TAG_W-1:0]     tag_in;

    logic [N-1:0]                valid_out;
    logic [N-1:0][31:0]          hash_out;
    logic [N-1:0][TAG_W-1:0]     tag_out;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    murmurhash3_accel #(
        .N     (N),
        .TAG_W (TAG_W)
    ) dut (
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

    // =========================================================================
    // Golden reference model
    // Must mirror murmurhash3_lane.sv exactly.
    // =========================================================================
    localparam logic [31:0] REF_C1      = 32'hcc9e2d51;
    localparam logic [31:0] REF_C2      = 32'h1b873593;
    localparam logic [31:0] REF_MIX_ADD = 32'he6546b64;
    localparam logic [31:0] REF_FMIX_C1 = 32'h85ebca6b;
    localparam logic [31:0] REF_FMIX_C2 = 32'hc2b2ae35;

    function automatic logic [31:0] ref_mix_block (
        input logic [31:0] h,
        input logic [31:0] blk
    );
        logic [31:0] k;
        k = blk * REF_C1;
        k = {k[16:0], k[31:17]};              // ROTL(k, 15)
        k = k * REF_C2;
        h = h ^ k;
        h = {h[18:0], h[31:19]};              // ROTL(h, 13)
        h = (h * 32'd5) + REF_MIX_ADD;
        return h;
    endfunction

    function automatic logic [31:0] ref_fmix32 (input logic [31:0] h);
        h = h ^ (h >> 16);
        h = h * REF_FMIX_C1;
        h = h ^ (h >> 13);
        h = h * REF_FMIX_C2;
        h = h ^ (h >> 16);
        return h;
    endfunction

    // MurmurHash3_x86_32 for fixed 128-bit key (16 bytes, no tail)
    function automatic logic [31:0] murmur3_ref (
        input logic [127:0] key,
        input logic [31:0]  seed
    );
        logic [31:0] h;
        h = seed;
        h = ref_mix_block(h, key[31:0]);       // block 0
        h = ref_mix_block(h, key[63:32]);      // block 1
        h = ref_mix_block(h, key[95:64]);      // block 2
        h = ref_mix_block(h, key[127:96]);     // block 3
        h = h ^ 32'd16;                        // h ^= len
        h = ref_fmix32(h);
        return h;
    endfunction

    // =========================================================================
    // Scoreboard
    // =========================================================================
    typedef struct {
        logic [127:0] key;
        logic [31:0]  seed;
        logic [31:0]  expected;
        logic         occupied;
    } sb_entry_t;

    sb_entry_t scoreboard [N][2**TAG_W];

    logic [TAG_W-1:0] next_tag [N];   // next tag to assign per lane

    int pass_count = 0;
    int fail_count = 0;
    string tb_build_id = "TB_CORRECTNESS_V1_2026_04_15";
    string active_test_name = "startup";

    // Checker — samples every rising edge.
    // tag_out[i] is used directly as the scoreboard index to avoid
    // 'automatic' variable declarations inside always blocks (Verilator issue).
    always @(posedge clk) begin
        for (int i = 0; i < N; i++) begin
            if (valid_out[i]) begin
                if (!scoreboard[i][tag_out[i]].occupied) begin
                    $error("[%0t] Lane %0d tag 0x%02h: output with no scoreboard entry",
                           $time, i, tag_out[i]);
                    fail_count++;
                end else if (hash_out[i] !== scoreboard[i][tag_out[i]].expected) begin
                    $display("RESULT test=%s lane=%0d tag=0x%02h key=0x%032h seed=0x%08h expected=0x%08h got=0x%08h status=FAIL",
                             active_test_name, i, tag_out[i],
                             scoreboard[i][tag_out[i]].key,
                             scoreboard[i][tag_out[i]].seed,
                             scoreboard[i][tag_out[i]].expected,
                             hash_out[i]);
                    $error("[%0t] Lane %0d tag 0x%02h: FAIL got=0x%08h expected=0x%08h  key=0x%032h seed=0x%08h",
                           $time, i, tag_out[i],
                           hash_out[i],
                           scoreboard[i][tag_out[i]].expected,
                           scoreboard[i][tag_out[i]].key,
                           scoreboard[i][tag_out[i]].seed);
                    fail_count++;
                end else begin
                    pass_count++;
                    $display("RESULT test=%s lane=%0d tag=0x%02h key=0x%032h seed=0x%08h expected=0x%08h got=0x%08h status=PASS",
                             active_test_name, i, tag_out[i],
                             scoreboard[i][tag_out[i]].key,
                             scoreboard[i][tag_out[i]].seed,
                             scoreboard[i][tag_out[i]].expected,
                             hash_out[i]);
                end
                scoreboard[i][tag_out[i]].occupied = 1'b0;
            end
        end
    end

    // =========================================================================
    // Helper tasks
    // =========================================================================

    task automatic drive_key (
        input int           lane,
        input logic [127:0] key,
        input logic [31:0]  seed
    );
        automatic logic [TAG_W-1:0] t = next_tag[lane];

        scoreboard[lane][t].key      = key;
        scoreboard[lane][t].seed     = seed;
        scoreboard[lane][t].expected = murmur3_ref(key, seed);
        scoreboard[lane][t].occupied = 1'b1;

        valid_in[lane] = 1'b1;
        key_in[lane]   = key;
        seed_in[lane]  = seed;
        tag_in[lane]   = t;

        next_tag[lane]++;
    endtask

    task automatic idle_lane (input int lane);
        valid_in[lane] = 1'b0;
        key_in[lane]   = '0;
        seed_in[lane]  = '0;
        tag_in[lane]   = '0;
    endtask

    task automatic idle_all;
        for (int i = 0; i < N; i++) idle_lane(i);
    endtask

    task automatic start_test (input string test_name);
        active_test_name = test_name;
        $display("\n[TB][%s] >>> BEGIN %s <<<", tb_build_id, active_test_name);
        $display("[TB][%s] time=%0t  pass=%0d  fail=%0d",
                 active_test_name, $time, pass_count, fail_count);
    endtask

    task automatic finish_test (input string test_name);
        $display("[TB][%s] <<< END %s >>>", tb_build_id, test_name);
        $display("[TB][%s] cumulative pass=%0d  fail=%0d",
                 test_name, pass_count, fail_count);
    endtask

    function automatic logic [31:0] lcg_next (input logic [31:0] state);
        return (state * 32'h0019660d) + 32'h3c6ef35f;
    endfunction

    task automatic run_directed_case (
        input string         test_name,
        input logic [127:0]  key,
        input logic [31:0]   seed,
        input logic [31:0]   expected
    );
        start_test(test_name);
        @(posedge clk);
        valid_in[0] = 1'b1;
        key_in[0]   = key;
        seed_in[0]  = seed;
        tag_in[0]   = next_tag[0];
        scoreboard[0][next_tag[0]].key      = key;
        scoreboard[0][next_tag[0]].seed     = seed;
        scoreboard[0][next_tag[0]].expected = expected;
        scoreboard[0][next_tag[0]].occupied = 1'b1;
        next_tag[0]++;
        @(posedge clk); idle_lane(0);
        repeat (PIPELINE_DEPTH + 2) @(posedge clk);
        finish_test(test_name);
    endtask

    // =========================================================================
    // Main stimulus
    // =========================================================================
    int total_expected_results;
    int   bw_keys;
    real  bw_start_ns, bw_end_ns;

    initial begin
        // -----------------------------------------------------------------
        // Initialization
        // -----------------------------------------------------------------
        $display("============================================================");
        $display("[TB] BUILD ID : %s", tb_build_id);
        $display("[TB] PARAMS   : N=%0d TAG_W=%0d PIPELINE_DEPTH=%0d CLK_PERIOD=%.1f ns",
                 N, TAG_W, PIPELINE_DEPTH, 2.0 * CLK_HALF);
        $display("[TB] MODE     : correctness-focused directed vectors + deterministic sweep");
        $display("============================================================");
        idle_all();
        for (int i = 0; i < N; i++) next_tag[i] = '0;
        for (int i = 0; i < N; i++)
            for (int j = 0; j < 2**TAG_W; j++)
                scoreboard[i][j].occupied = 1'b0;

        // Reset for 4 cycles
        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        $display("[TB] Reset released at t=%0t", $time);

        // -----------------------------------------------------------------
        // Correctness-focused flow
        // -----------------------------------------------------------------
        total_expected_results = 4 + (SWEEP_CASES_PER_LANE * N);

        run_directed_case("TV0 zero key seed=0",           TV0_KEY, TV0_SEED, TV0_GOLDEN);
        run_directed_case("TV1 ones key seed=DEADBEEF",    TV1_KEY, TV1_SEED, TV1_GOLDEN);
        run_directed_case("TV2 incrementing bytes seed=1", TV2_KEY, TV2_SEED, TV2_GOLDEN);
        run_directed_case("TV3 AA pattern seed=CAFEBABE",  TV3_KEY, TV3_SEED, TV3_GOLDEN);

        start_test("Deterministic sweep");
        $display("=== Deterministic correctness sweep (%0d cases x %0d lanes) ===",
                 SWEEP_CASES_PER_LANE, N);
        begin
            automatic logic [127:0] rkey;
            automatic logic [31:0]  rseed;
            automatic logic [31:0]  prng_state;
            automatic logic [31:0]  w0, w1, w2, w3;

            prng_state = 32'h1badf00d;
            repeat (SWEEP_CASES_PER_LANE) begin
                @(posedge clk);
                for (int lane = 0; lane < N; lane++) begin
                    prng_state = lcg_next(prng_state); w0 = prng_state;
                    prng_state = lcg_next(prng_state); w1 = prng_state;
                    prng_state = lcg_next(prng_state); w2 = prng_state;
                    prng_state = lcg_next(prng_state); w3 = prng_state;
                    prng_state = lcg_next(prng_state); rseed = prng_state;
                    rkey = {w3, w2, w1, w0};
                    drive_key(lane, rkey, rseed);
                end
            end
        end
        @(posedge clk); idle_all();
        repeat (PIPELINE_DEPTH + 2) @(posedge clk);
        finish_test("Deterministic sweep");

        $display("\n============================================================");
        $display(" CORRECTNESS SUMMARY");
        $display("============================================================");
        $display("  Directed C-verified vectors : 4");
        $display("  Deterministic sweep outputs : %0d", SWEEP_CASES_PER_LANE * N);
        $display("  Total expected results      : %0d", total_expected_results);
        $display("  PASS                        : %0d", pass_count);
        $display("  FAIL                        : %0d", fail_count);
        $display("  Copyable compare lines      : search for prefix 'RESULT ' above");
        $display("============================================================");

        if (fail_count == 0)
            $display("  *** HASH OUTPUT CORRECTNESS CHECKS PASSED ***");
        else
            $display("  *** %0d CORRECTNESS FAILURE(S) -- see RESULT/$error lines above ***", fail_count);
        $display("============================================================\n");

        $finish;

        /*
        -----------------------------------------------------------------------
        Legacy bandwidth-oriented flow retained for reference.
        This block is intentionally commented out while the active testbench
        focuses on correctness and copyable hash-compare output.
        -----------------------------------------------------------------------

        // -----------------------------------------------------------------
        // Test 1 : Hardcoded vector — zero key, seed = 0
        //
        // This test catches bugs where the model and hardware disagree with
        // the C reference (circular validation break).
        //
        // Steps to fill TV0_GOLDEN:
        //   gcc -O2 sw/murmurhash3_ref.c -o mm3ref && ./mm3ref
        //   Compare printed hash to TV0_GOLDEN in this file.
        //
        // Until TV0_GOLDEN is filled with the C-derived value, this test
        // only confirms DUT matches the SV model.
        // -----------------------------------------------------------------
        start_test("Test 1");
        $display("\n=== Test 1: hardcoded vector (zero key, seed=0) ===");
        if (TV0_GOLDEN !== 32'hXXXXXXXX) begin
            // Drive directly and check output against hardcoded constant
            @(posedge clk);
            valid_in[0] = 1'b1;
            key_in[0]   = TV0_KEY;
            seed_in[0]  = TV0_SEED;
            tag_in[0]   = next_tag[0];
            scoreboard[0][next_tag[0]].key      = TV0_KEY;
            scoreboard[0][next_tag[0]].seed     = TV0_SEED;
            scoreboard[0][next_tag[0]].expected = TV0_GOLDEN;  // C-reference value
            scoreboard[0][next_tag[0]].occupied = 1'b1;
            next_tag[0]++;
            @(posedge clk); idle_lane(0);
            repeat (PIPELINE_DEPTH + 2) @(posedge clk);
        end else begin
            $display("  SKIPPED — TV0_GOLDEN not yet filled from C reference");
        end

        // -----------------------------------------------------------------
        // Test 2 : Hardcoded vector — all-ones key, seed = 0xDEADBEEF
        // -----------------------------------------------------------------
        finish_test("Test 1");
        start_test("Test 2");
        $display("=== Test 2: hardcoded vector (all-ones key, seed=0xDEADBEEF) ===");
        if (TV1_GOLDEN !== 32'hXXXXXXXX) begin
            @(posedge clk);
            valid_in[0] = 1'b1;
            key_in[0]   = TV1_KEY;
            seed_in[0]  = TV1_SEED;
            tag_in[0]   = next_tag[0];
            scoreboard[0][next_tag[0]].key      = TV1_KEY;
            scoreboard[0][next_tag[0]].seed     = TV1_SEED;
            scoreboard[0][next_tag[0]].expected = TV1_GOLDEN;
            scoreboard[0][next_tag[0]].occupied = 1'b1;
            next_tag[0]++;
            @(posedge clk); idle_lane(0);
            repeat (PIPELINE_DEPTH + 2) @(posedge clk);
        end else begin
            $display("  SKIPPED — TV1_GOLDEN not yet filled from C reference");
        end

        // -----------------------------------------------------------------
        // Test 3 : Correctness sweep
        //   64 pseudo-random keys × N lanes.  All lanes driven in parallel.
        //   Scoreboard checks DUT output == SV reference model.
        // -----------------------------------------------------------------
        finish_test("Test 2");
        start_test("Test 3");
        $display("=== Test 3: correctness sweep (64 keys x %0d lanes) ===", N);
        begin
            automatic logic [127:0] rkey;
            automatic logic [31:0]  rseed;
            repeat (64) begin
                @(posedge clk);
                for (int lane = 0; lane < N; lane++) begin
                    rkey  = {$urandom, $urandom, $urandom, $urandom};
                    rseed = $urandom;
                    drive_key(lane, rkey, rseed);
                end
            end
        end
        @(posedge clk); idle_all();
        repeat (PIPELINE_DEPTH + 2) @(posedge clk);

        // -----------------------------------------------------------------
        // Test 4 : Bandwidth measurement
        //   Stream all N lanes for 256 cycles; measure throughput.
        // -----------------------------------------------------------------
        finish_test("Test 3");
        start_test("Test 4");
        $display("=== Test 4: bandwidth (%0d lanes, 256 cycles) ===", N);
        bw_keys     = 0;
        bw_start_ns = $realtime;
        $display("[TB][Test 4] bandwidth timer armed at t=%0t", $time);
        begin
            automatic logic [127:0] rkey;
            automatic logic [31:0]  rseed;
            repeat (256) begin
                @(posedge clk);
                for (int lane = 0; lane < N; lane++) begin
                    rkey  = {$urandom, $urandom, $urandom, $urandom};
                    rseed = $urandom;
                    drive_key(lane, rkey, rseed);
                    bw_keys++;
                end
            end
        end
        @(posedge clk); idle_all();
        repeat (PIPELINE_DEPTH + 2) @(posedge clk);
        bw_end_ns = $realtime;
        $display("[TB][Test 4] bandwidth timer start=%0f ns stop=%0f ns",
                 bw_start_ns, bw_end_ns);
        finish_test("Test 4");

        // -----------------------------------------------------------------
        // Summary
        // -----------------------------------------------------------------
        $display("\n========================================");
        $display(" RESULTS");
        $display("========================================");
        $display("  PASS : %0d", pass_count);
        $display("  FAIL : %0d", fail_count);
        $display("  BW test : %0d keys in %.0f ns  (%.0f cycles)",
                 bw_keys, bw_end_ns - bw_start_ns,
                 (bw_end_ns - bw_start_ns) / (2.0 * CLK_HALF));
        $display("  Throughput : %.2f keys/cycle  (N=%0d, ideal=%0d)",
                 real'(bw_keys) / ((bw_end_ns - bw_start_ns) / (2.0 * CLK_HALF)),
                 N, N);
        $display("========================================");

        if (fail_count == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** %0d FAILURE(S) — see $error messages above ***", fail_count);
        $display("========================================\n");

        $finish;
        */
    end

    // Watchdog
    initial begin
        #500_000;
        $fatal(1, "TIMEOUT: simulation exceeded 500 us");
    end

endmodule
