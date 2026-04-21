#!/usr/bin/env bash
# =============================================================================
# run_sweep.sh  —  Full simulation and CPU benchmark sweep
#
# Runs:
#   1. Correctness simulation  (tb_murmurhash3)  for N in {1 2 4 8 16 32}
#   2. Bandwidth sweep         (tb_bw_sweep)     for N in {1 2 4 8 16 32}
#   3. CPU baseline            (avx2_bench)
#
# Outputs:
#   results/correctness.csv
#   results/throughput.csv
#   results/cpu_baseline.txt
#
# Requirements:
#   xvlog / xelab / xsim  (Vivado 2022+)
#   gcc
#
# Usage (from repo root):
#   bash scripts/run_sweep.sh
#   bash scripts/run_sweep.sh --n-keys 1000000    # larger sweep
#   bash scripts/run_sweep.sh --skip-correctness   # BW + CPU only
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"
RTL_DIR="$REPO/rtl"
TB_DIR="$REPO/tb"
SW_DIR="$REPO/sw"
SIM_DIR="$REPO/sim"
LOG_DIR="$SIM_DIR/logs"
RESULTS_DIR="$REPO/results"

mkdir -p "$LOG_DIR" "$RESULTS_DIR"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
LANE_COUNTS=(1 2 4 8 16 32)
N_KEYS=100000      # keys per lane for BW test; override with --n-keys
SWEEP_KEYS=1000    # keys per lane for correctness sweep; bump to 10000 for paper
SEED="464384013"   # 0x1BADF00D in decimal — override with --seed=<int>; pass decimal for shell safety
RUN_CORRECTNESS=1

for arg in "$@"; do
    case "$arg" in
        --n-keys=*)       N_KEYS="${arg#*=}" ;;
        --n-keys)         shift; N_KEYS="$1" ;;
        --sweep-keys=*)   SWEEP_KEYS="${arg#*=}" ;;
        --seed=*)         SEED="${arg#*=}" ;;
        --skip-correctness) RUN_CORRECTNESS=0 ;;
    esac
done

echo "============================================================"
echo " MurmurHash3 Accelerator Sweep"
echo " Lanes: ${LANE_COUNTS[*]}"
echo " N_KEYS (BW test, per lane):     $N_KEYS"
echo " SWEEP_KEYS (correctness, /lane): $SWEEP_KEYS"
echo " SEED:                            $SEED"
echo "============================================================"

# ---------------------------------------------------------------------------
# RTL source list (compile once — same sources for all N)
# ---------------------------------------------------------------------------
RTL_SRCS=(
    "$RTL_DIR/murmurhash3_lane.sv"
    "$RTL_DIR/murmurhash3_accel.sv"
)
TB_CORR="$TB_DIR/tb_murmurhash3.sv"
TB_BW="$TB_DIR/tb_bw_sweep.sv"

# Headers for CSVs
echo "N,test,pass,fail" > "$RESULTS_DIR/correctness.csv"
echo "N,duty_pct,valid_in_cycles,total_hashes,hashes_per_cycle" > "$RESULTS_DIR/throughput.csv"

# ---------------------------------------------------------------------------
# Helper: compile RTL + TB
# ---------------------------------------------------------------------------
compile_sv() {
    local label="$1"; shift
    xvlog --sv --work work "$@" 2>&1 | tee "$LOG_DIR/xvlog_${label}.log"
}

# ---------------------------------------------------------------------------
# 1. Correctness sweep
# ---------------------------------------------------------------------------
if [[ "$RUN_CORRECTNESS" -eq 1 ]]; then
    echo ""
    echo "--- Correctness sweep ---"
    for N in "${LANE_COUNTS[@]}"; do
        LABEL="corr_N${N}"
        SNAP="tb_corr_snap_N${N}"
        echo "[correctness] N=$N ..."

        compile_sv "$LABEL" "${RTL_SRCS[@]}" "$TB_CORR"

        xelab --sv \
            --snapshot "$SNAP" \
            --generic_top "N=$N" \
            --generic_top "TAG_W=8" \
            --generic_top "SWEEP_KEYS_PER_LANE=$SWEEP_KEYS" \
            --generic_top "SEED=$SEED" \
            --generic_top "VERBOSE=0" \
            tb_murmurhash3 \
            2>&1 | tee "$LOG_DIR/xelab_${LABEL}.log"

        xsim "$SNAP" \
            --runall \
            --log "$LOG_DIR/xsim_${LABEL}.log"

        # Parse pass/fail from log
        PASS=$(grep -c "status=PASS" "$LOG_DIR/xsim_${LABEL}.log" || true)
        FAIL=$(grep -c "status=FAIL" "$LOG_DIR/xsim_${LABEL}.log" || true)
        echo "$N,correctness,$PASS,$FAIL" >> "$RESULTS_DIR/correctness.csv"
        echo "  N=$N: PASS=$PASS  FAIL=$FAIL"
    done
fi

# ---------------------------------------------------------------------------
# 2. Bandwidth sweep
# ---------------------------------------------------------------------------
echo ""
echo "--- Bandwidth sweep (N_KEYS=$N_KEYS per lane) ---"
for N in "${LANE_COUNTS[@]}"; do
    LABEL="bw_N${N}"
    SNAP="tb_bw_snap_N${N}"
    echo "[bandwidth] N=$N ..."

    compile_sv "$LABEL" "${RTL_SRCS[@]}" "$TB_BW"

    xelab --sv \
        --snapshot "$SNAP" \
        --generic_top "N=$N" \
        --generic_top "N_KEYS=$N_KEYS" \
        --generic_top "SEED=$SEED" \
        tb_bw_sweep \
        2>&1 | tee "$LOG_DIR/xelab_${LABEL}.log"

    xsim "$SNAP" \
        --runall \
        --log "$LOG_DIR/xsim_${LABEL}.log"

    # Parse BW_RESULT lines
    grep "^BW_RESULT " "$LOG_DIR/xsim_${LABEL}.log" | \
    while read -r line; do
        n=$(     echo "$line" | grep -oP 'N=\K[0-9]+')
        duty=$(  echo "$line" | grep -oP 'duty=\K[0-9]+')
        vic=$(   echo "$line" | grep -oP 'valid_in_cycles=\K[0-9]+')
        hashes=$(echo "$line" | grep -oP 'total_hashes=\K[0-9]+')
        hpc=$(   echo "$line" | grep -oP 'hashes_per_cycle=\K[0-9.]+')
        echo "$n,$duty,$vic,$hashes,$hpc" >> "$RESULTS_DIR/throughput.csv"
    done

    grep "^BW_RESULT " "$LOG_DIR/xsim_${LABEL}.log" || true
done

# ---------------------------------------------------------------------------
# 3. CPU baseline
# ---------------------------------------------------------------------------
echo ""
echo "--- CPU baseline ---"
CPU_LOG="$RESULTS_DIR/cpu_baseline.txt"

# Try to build with AVX2 first (covers Linux x86 lab machines).
# Fall back to scalar-only build (ARM Linux, old x86 without AVX2).
if gcc -O3 -mavx2 -lm -o "$SW_DIR/avx2_bench" "$SW_DIR/avx2_bench.c" 2>/dev/null; then
    echo "[cpu] Built with AVX2 support — running scalar + AVX2 benchmark..."
    "$SW_DIR/avx2_bench" | tee "$CPU_LOG"
else
    echo "[cpu] AVX2 not available — building scalar-only benchmark..."
    gcc -O3 -DNO_AVX2 -lm -o "$SW_DIR/avx2_bench" "$SW_DIR/avx2_bench.c"
    echo "[cpu] Running scalar benchmark..."
    "$SW_DIR/avx2_bench" | tee "$CPU_LOG"
    echo "CPU_RESULT impl=avx2x8 n_keys=0 elapsed_s=0 throughput_mhps=0 stddev_mhps=0 hashpj=0" >> "$CPU_LOG"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Sweep complete."
echo "  Correctness : $RESULTS_DIR/correctness.csv"
echo "  Throughput  : $RESULTS_DIR/throughput.csv"
echo "  CPU baseline: $RESULTS_DIR/cpu_baseline.txt"
echo "  Logs        : $LOG_DIR/"
echo ""
echo " Next step: python3 scripts/analysis.py"
echo "============================================================"
