// =============================================================================
// tb_bw_sweep.sv  —  Bandwidth and throttled-valid sweep testbench
//
// Tests:
//   T1 : Full rate (100 % duty)    — N_KEYS per lane
//   T2 : Throttled 75 % duty       — every 4 cycles, 3 valid, 1 idle
//   T3 : Throttled 50 % duty       — alternating valid/idle
//   T4 : Throttled 25 % duty       — 1 valid every 4 cycles
//
// Output lines (grep for prefix "BW_RESULT"):
//   BW_RESULT N=<n> duty=<pct> valid_in_cycles=<v> total_hashes=<h>
//             hashes_per_cycle=<f>
//
// The run_sweep.sh script parses these lines into results/throughput.csv.
// NOT synthesizable.
// =============================================================================

`timescale 1ns/1ps

module tb_bw_sweep #(
    parameter int N              = 4,
    parameter int PIPELINE_DEPTH = 11,
    parameter int N_KEYS         = 100_000,  // keys per lane; override to 1_000_000 in sweep
    // Per proposal §3.4 the power study runs three independently seeded
    // streams. Override SEED at elab to produce different stimulus traces
    // for SAIF capture without recompiling.
    parameter int SEED           = 32'hBEEF_0000,
    // When non-zero, only the 100% duty test runs — useful when capturing
    // SAIF for a single steady-state operating point.
    parameter int FULL_RATE_ONLY = 0
);
    localparam realtime CLK_HALF = 5.0;   // 10 ns period → 100 MHz
    localparam int      TAG_W   = 1;      // minimal tag; scoreboard not used in BW test

    // =========================================================================
    // Clock & reset
    // =========================================================================
    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #CLK_HALF clk = ~clk;

    // =========================================================================
    // DUT wires
    // =========================================================================
    logic [N-1:0]            valid_in;
    logic [N-1:0][127:0]     key_in;
    logic [N-1:0][31:0]      seed_in;
    logic [N-1:0][TAG_W-1:0] tag_in;

    logic [N-1:0]            valid_out;
    logic [N-1:0][31:0]      hash_out;
    logic [N-1:0][TAG_W-1:0] tag_out;

    murmurhash3_accel #(.N(N), .TAG_W(TAG_W)) dut (
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
    // Global output counter — reset by test tasks
    // =========================================================================
    longint g_hash_count = 0;
    logic   g_count_en   = 1'b0;

    always @(posedge clk) begin
        if (g_count_en) begin
            for (int i = 0; i < N; i++)
                if (valid_out[i]) g_hash_count++;
        end
    end

    // =========================================================================
    // LCG PRNG (same constants as correctness TB for reproducibility)
    // =========================================================================
    function automatic logic [31:0] lcg_next(input logic [31:0] s);
        return (s * 32'h0019660d) + 32'h3c6ef35f;
    endfunction

    // =========================================================================
    // BW test task
    //   throttle_pct : 100 / 75 / 50 / 25
    //   n_keys       : how many valid input cycles to drive (per-lane count)
    // =========================================================================
    task automatic run_bw_test(
        input int throttle_pct,
        input int n_keys
    );
        automatic logic [31:0] prng = SEED ^ 32'(throttle_pct);
        automatic int          valid_cyc = 0;   // cycles where valid_in was 1
        automatic int          total_cyc = 0;   // all driven cycles
        automatic realtime     t_start, t_end;
        automatic real         elapsed_ns, elapsed_cyc, hpc;
        automatic logic        do_valid;

        // Reset counter
        g_hash_count = 0;
        g_count_en   = 1'b1;
        t_start      = $realtime;

        // Drive keys
        while (valid_cyc < n_keys) begin
            @(posedge clk);

            // Throttle decision
            case (throttle_pct)
                100: do_valid = 1'b1;
                 75: do_valid = (total_cyc % 4) != 3;
                 50: do_valid = (total_cyc % 2) == 0;
                 25: do_valid = (total_cyc % 4) == 0;
              default: do_valid = 1'b1;
            endcase

            if (do_valid && valid_cyc < n_keys) begin
                for (int i = 0; i < N; i++) begin
                    prng          = lcg_next(prng);
                    valid_in[i]   = 1'b1;
                    key_in[i]     = {prng,
                                     lcg_next(prng),
                                     lcg_next(lcg_next(prng)),
                                     lcg_next(lcg_next(lcg_next(prng)))};
                    seed_in[i]    = 32'hDEAD_BEEF;
                    tag_in[i]     = '0;
                end
                valid_cyc++;
            end else begin
                for (int i = 0; i < N; i++) begin
                    valid_in[i] = 1'b0;
                    key_in[i]   = '0;
                    seed_in[i]  = '0;
                    tag_in[i]   = '0;
                end
            end
            total_cyc++;
        end

        // Idle all lanes
        @(posedge clk);
        for (int i = 0; i < N; i++) valid_in[i] = 1'b0;

        // Drain pipeline
        repeat (PIPELINE_DEPTH + 2) @(posedge clk);

        t_end       = $realtime;
        g_count_en  = 1'b0;

        elapsed_ns  = real'(t_end - t_start);
        elapsed_cyc = elapsed_ns / (2.0 * CLK_HALF);
        hpc         = real'(g_hash_count) / elapsed_cyc;

        $display("BW_RESULT N=%0d duty=%0d valid_in_cycles=%0d total_hashes=%0d hashes_per_cycle=%.6f",
                 N, throttle_pct, valid_cyc, g_hash_count, hpc);
        $display("  [detail] elapsed_cycles=%.1f  ideal_hashes=%0d  efficiency=%.4f",
                 elapsed_cyc, valid_cyc * N, hpc / real'(N));
    endtask

    // =========================================================================
    // SAIF capture (Vivado xsim)
    //
    // xsim does NOT support the IEEE-1364 $set_toggle_region / $toggle_*
    // system tasks. SAIF dumping in xsim is driven from the simulator Tcl
    // prompt instead, e.g.:
    //
    //   open_saif results/saif/run.saif
    //   log_saif  [get_objects -r /tb_bw_sweep/dut/*]
    //   run all
    //   close_saif
    //
    // No testbench hooks are required. Leave this block as documentation.
    // =========================================================================

    // =========================================================================
    // Main stimulus
    // =========================================================================
    initial begin
        $display("============================================================");
        $display("[BW_TB] N=%0d  PIPELINE_DEPTH=%0d  N_KEYS=%0d  SEED=0x%08h  CLK=100MHz  FULL_RATE_ONLY=%0d",
                 N, PIPELINE_DEPTH, N_KEYS, SEED, FULL_RATE_ONLY);
        $display("============================================================");

        for (int i = 0; i < N; i++) begin
            valid_in[i] = 1'b0;
            key_in[i]   = '0;
            seed_in[i]  = '0;
            tag_in[i]   = '0;
        end

        // Reset
        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        @(posedge clk);

        // T1 : 100 % duty
        $display("[BW_TB] T1: full-rate (100%%) — %0d keys/lane", N_KEYS);
        run_bw_test(100, N_KEYS);

        if (FULL_RATE_ONLY == 0) begin
            // T2 : 75 %
            $display("[BW_TB] T2: throttled 75%% — %0d keys/lane", N_KEYS);
            run_bw_test(75, N_KEYS);

            // T3 : 50 %
            $display("[BW_TB] T3: throttled 50%% — %0d keys/lane", N_KEYS);
            run_bw_test(50, N_KEYS);

            // T4 : 25 %
            $display("[BW_TB] T4: throttled 25%% — %0d keys/lane", N_KEYS);
            run_bw_test(25, N_KEYS);
        end

        $display("============================================================");
        $display("[BW_TB] Done. Grep for 'BW_RESULT' in this log.");
        $display("============================================================");
        $finish;
    end

    // Watchdog — scale with N_KEYS
    initial begin
        #(real'(N_KEYS) * 50.0 * 10.0 + 100_000.0);
        $fatal(1, "BW_TB TIMEOUT");
    end

endmodule
