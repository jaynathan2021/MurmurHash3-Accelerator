# =============================================================================
# run_scaling_study.tcl
#
# Vivado scaling study for MurmurHash3 accelerator on Nexys A4.
# Target device : xc7a100tcsg324-1  (Artix-7, Nexys A4)
#
# For each N in {1, 2, 4, 8}:
#   1. Creates an in-memory project
#   2. Reads RTL sources (murmurhash3_lane.sv, murmurhash3_accel.sv)
#   3. Sets the top-level generic N
#   4. Applies timing constraints (nexys_a4.xdc)
#   5. Runs synthesis (synth_design)
#   6. Runs implementation (opt_design, place_design, route_design)
#   7. Reports: utilization, timing summary, power
#
# Reports are written to:
#   vivado/reports/utilization_N{n}.rpt
#   vivado/reports/timing_N{n}.rpt
#   vivado/reports/power_N{n}.rpt
#
# Usage (from repo root):
#   vivado -mode batch -source vivado/run_scaling_study.tcl
# =============================================================================

# -----------------------------------------------------------------------------
# Paths — resolve relative to this script's directory so the script works
# regardless of where Vivado is invoked from.
# -----------------------------------------------------------------------------
set script_dir  [file dirname [file normalize [info script]]]
set repo_root   [file dirname $script_dir]
set rtl_dir     [file join $repo_root rtl]
set cst_dir     [file join $repo_root constraints]
set rpt_dir     [file join $script_dir reports]

file mkdir $rpt_dir

set part "xc7a100tcsg324-1"

# Lane counts to sweep
set lane_counts {1 2 4 8}

foreach N $lane_counts {
    puts ""
    puts "============================================================"
    puts " Starting N = $N  ($part)"
    puts "============================================================"

    # ------------------------------------------------------------------
    # Create in-memory project (no disk project files written)
    # ------------------------------------------------------------------
    create_project -in_memory -part $part

    set_property target_language SystemVerilog [current_project]

    # ------------------------------------------------------------------
    # Add RTL sources
    # ------------------------------------------------------------------
    read_verilog -sv [file join $rtl_dir murmurhash3_lane.sv]
    read_verilog -sv [file join $rtl_dir murmurhash3_accel.sv]

    # ------------------------------------------------------------------
    # Add constraints
    # ------------------------------------------------------------------
    read_xdc [file join $cst_dir nexys_a4.xdc]

    # ------------------------------------------------------------------
    # Synthesis
    # Flatten hierarchy for accurate resource counting per lane.
    # Generic N is passed here; TAG_W is fixed at 8 (matches testbench).
    # ------------------------------------------------------------------
    puts "  \[N=$N\] Running synthesis..."
    synth_design \
        -top    murmurhash3_accel \
        -part   $part \
        -generic "N=$N TAG_W=8" \
        -flatten_hierarchy full

    # ------------------------------------------------------------------
    # Implementation
    # ------------------------------------------------------------------
    puts "  \[N=$N\] Running opt_design..."
    opt_design

    puts "  \[N=$N\] Running place_design..."
    place_design

    puts "  \[N=$N\] Running route_design..."
    route_design

    # ------------------------------------------------------------------
    # Reports
    # ------------------------------------------------------------------
    puts "  \[N=$N\] Writing reports..."

    report_utilization \
        -file [file join $rpt_dir "utilization_N${N}.rpt"] \
        -hierarchical

    report_timing_summary \
        -file      [file join $rpt_dir "timing_N${N}.rpt"] \
        -max_paths 10 \
        -report_unconstrained

    report_power \
        -file [file join $rpt_dir "power_N${N}.rpt"]

    puts "  \[N=$N\] Reports written to $rpt_dir"

    # ------------------------------------------------------------------
    # Close the in-memory project before starting the next iteration
    # ------------------------------------------------------------------
    close_project
}

# -----------------------------------------------------------------------------
# Print summary table to console (Fmax, LUT, FF, DSP, BRAM)
# -----------------------------------------------------------------------------
puts ""
puts "============================================================"
puts " SCALING STUDY COMPLETE — Summary"
puts "============================================================"
puts [format "%-6s  %-12s  %-10s  %-10s  %-8s  %-8s" \
      "N" "WNS (ns)" "LUTs" "FFs" "DSPs" "BRAMs"]
puts [string repeat "-" 62]

foreach N $lane_counts {
    set rpt [file join $rpt_dir "timing_N${N}.rpt"]
    set util [file join $rpt_dir "utilization_N${N}.rpt"]

    # Parse WNS from timing report
    set wns "N/A"
    if {[file exists $rpt]} {
        set fh [open $rpt r]
        while {[gets $fh line] >= 0} {
            if {[regexp {WNS\(ns\)\s+([-0-9.]+)} $line -> val]} {
                set wns $val
                break
            }
        }
        close $fh
    }

    # Parse LUT, FF, DSP, BRAM from utilization report
    set luts "N/A"; set ffs "N/A"; set dsps "N/A"; set brams "N/A"
    if {[file exists $util]} {
        set fh [open $util r]
        while {[gets $fh line] >= 0} {
            if {[regexp {^\|\s*Slice LUTs\s*\|\s*([0-9]+)} $line -> v]} { set luts $v }
            if {[regexp {^\|\s*Slice Registers\s*\|\s*([0-9]+)} $line -> v]} { set ffs $v }
            if {[regexp {^\|\s*DSPs\s*\|\s*([0-9]+)} $line -> v]} { set dsps $v }
            if {[regexp {^\|\s*Block RAM Tile\s*\|\s*([0-9]+)} $line -> v]} { set brams $v }
        }
        close $fh
    }

    puts [format "%-6s  %-12s  %-10s  %-10s  %-8s  %-8s" \
          $N $wns $luts $ffs $dsps $brams]
}

puts "============================================================"
puts " Reports in: $rpt_dir"
puts "============================================================"
