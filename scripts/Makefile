# =============================================================================
# Makefile — MurmurHash3 Accelerator
#
# Targets:
#   sim        Correctness sim (xsim) — drives directed + sweep vectors
#   bw-sim     Bandwidth sim across 100/75/50/25 % duty cycles
#   sweep      Run correctness + bw across N in {1,2,4,8,16,32}
#   ref        Build and run the C reference (prints golden vectors)
#   cpu-bench  Build & run scalar + AVX2 CPU benchmark
#   plot       Run scripts/analysis.py to generate figures
#   clean      Remove generated artifacts
#
# Requirements:
#   - Vivado 2022+ on PATH  (for sim / bw-sim / saif-sim / sweep)
#   - gcc                   (for ref / cpu-bench)
#
# Usage from repo root:
#   make -f scripts/Makefile sim
#   make -f scripts/Makefile sim N=8 SWEEP_KEYS=10000          # §3.2 paper run
#   make -f scripts/Makefile bw-sim N=8 N_KEYS=1000000
#   make -f scripts/Makefile sweep
#   make -f scripts/Makefile ref
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
N          ?= 4                     # number of parallel lanes for simulation
TAG_W      ?= 8
N_KEYS     ?= 100000                # keys per lane for BW test (use 1000000 for paper data)
SWEEP_KEYS ?= 1000                  # keys per lane for correctness sweep (use 10000 for paper)
SEED       ?= 464384013             # PRNG seed (decimal; default = 0x1BADF00D); vary for §3.4 power study
VERBOSE    ?= 0                     # 1 = print every PASS line in correctness sweep

REPO     := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))..
RTL_DIR  := $(REPO)/rtl
TB_DIR   := $(REPO)/tb
SIM_DIR  := $(REPO)/sim
LOG_DIR  := $(SIM_DIR)/logs
SW_DIR   := $(REPO)/sw

TOP_SIM  := tb_murmurhash3        # simulation top
TOP_RTL  := murmurhash3_accel     # synthesis top

XVLOG    := xvlog
XELAB    := xelab
XSIM     := xsim

# ---------------------------------------------------------------------------
# Source file lists
# ---------------------------------------------------------------------------
RTL_SRCS := $(RTL_DIR)/murmurhash3_lane.sv \
             $(RTL_DIR)/murmurhash3_accel.sv

TB_SRCS  := $(TB_DIR)/tb_murmurhash3.sv

# ---------------------------------------------------------------------------
# Derived names
# ---------------------------------------------------------------------------
SNAP     := $(TOP_SIM)_snap
XVLOG_LOG := $(LOG_DIR)/xvlog.log
XELAB_LOG := $(LOG_DIR)/xelab.log
XSIM_LOG  := $(LOG_DIR)/xsim.log

# ---------------------------------------------------------------------------
# Phony targets
# ---------------------------------------------------------------------------
.PHONY: all sim bw-sim sweep ref cpu-bench plot clean

all: sim

# ---------------------------------------------------------------------------
# bw-sim — bandwidth sweep simulation for one N value (default N=4)
#   make -f scripts/Makefile bw-sim N=8 N_KEYS=1000000
# ---------------------------------------------------------------------------
BW_SNAP  := tb_bw_sweep_snap
BW_SRCS  := $(RTL_SRCS) $(TB_DIR)/tb_bw_sweep.sv

bw-sim: | $(LOG_DIR)
	@echo ">>> [1/3] Compiling RTL + BW testbench (N=$(N))..."
	$(XVLOG) --sv --work work \
	    $(BW_SRCS) \
	    2>&1 | tee $(XVLOG_LOG)

	@echo ">>> [2/3] Elaborating $(BW_SNAP) (SEED=$(SEED))..."
	$(XELAB) --sv \
	    --snapshot $(BW_SNAP) \
	    --generic_top "N=$(N)" \
	    --generic_top "N_KEYS=$(N_KEYS)" \
	    --generic_top "SEED=$(SEED)" \
	    tb_bw_sweep \
	    2>&1 | tee $(XELAB_LOG)

	@echo ">>> [3/3] Running BW simulation..."
	$(XSIM) $(BW_SNAP) \
	    --runall \
	    --log $(SIM_DIR)/logs/xsim_bw.log

	@echo ""
	@echo "=== BW simulation complete. Grep for 'BW_RESULT' in log. ==="

# ---------------------------------------------------------------------------
# saif-sim — REMOVED.
#
# Vivado xsim does not support the IEEE-1364 $set_toggle_region / $toggle_*
# system tasks, so SAIF cannot be driven from inside the testbench. SAIF
# capture in xsim is done via the simulator Tcl prompt instead — see
# the comment block at the top of tb/tb_bw_sweep.sv for the recipe
# (open_saif / log_saif / run all / close_saif).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# sweep — run all N configs for both correctness and BW (requires xsim)
# ---------------------------------------------------------------------------
sweep: | $(LOG_DIR)
	bash $(REPO)/scripts/run_sweep.sh

# ---------------------------------------------------------------------------
# cpu-bench — build and run the scalar + AVX2 CPU baseline
#   On Linux x86 with AVX2: builds one binary with both scalar and AVX2 paths.
#   On ARM Linux or no AVX2: builds scalar-only, prints skip message for AVX2.
# ---------------------------------------------------------------------------
cpu-bench:
	@echo ">>> Building CPU benchmark (AVX2 if available)..."
	@if gcc -O3 -mavx2 -lm -o $(SW_DIR)/avx2_bench $(SW_DIR)/avx2_bench.c 2>/dev/null; then \
	    echo ">>> AVX2 available — running scalar + AVX2..."; \
	    $(SW_DIR)/avx2_bench; \
	else \
	    echo ">>> AVX2 not available — building scalar-only..."; \
	    gcc -O3 -DNO_AVX2 -lm -o $(SW_DIR)/avx2_bench $(SW_DIR)/avx2_bench.c; \
	    $(SW_DIR)/avx2_bench; \
	fi

# ---------------------------------------------------------------------------
# plot — run analysis.py to generate figures
# ---------------------------------------------------------------------------
plot:
	python3 $(REPO)/scripts/analysis.py

# ---------------------------------------------------------------------------
# sim — compile, elaborate, simulate using Vivado xsim
#
# xvlog compiles all .sv files into the xsim work library.
# xelab links the snapshot; -generic_top overrides N and TAG_W so you can
#   run "make sim N=8" without editing the testbench.
# xsim runs the snapshot until $finish.
# ---------------------------------------------------------------------------
sim: | $(LOG_DIR)
	@echo ">>> [1/3] Compiling RTL + testbench (N=$(N) TAG_W=$(TAG_W) SWEEP_KEYS=$(SWEEP_KEYS) SEED=$(SEED))..."
	$(XVLOG) --sv --work work \
	    $(RTL_SRCS) $(TB_SRCS) \
	    2>&1 | tee $(XVLOG_LOG)

	@echo ">>> [2/3] Elaborating $(SNAP)..."
	$(XELAB) --sv \
	    --snapshot $(SNAP) \
	    --debug typical \
	    --generic_top "N=$(N)" \
	    --generic_top "TAG_W=$(TAG_W)" \
	    --generic_top "SWEEP_KEYS_PER_LANE=$(SWEEP_KEYS)" \
	    --generic_top "SEED=$(SEED)" \
	    --generic_top "VERBOSE=$(VERBOSE)" \
	    $(TOP_SIM) \
	    2>&1 | tee $(XELAB_LOG)

	@echo ">>> [3/3] Running simulation..."
	$(XSIM) $(SNAP) \
	    --runall \
	    --log $(XSIM_LOG)

	@echo ""
	@echo "=== Simulation complete. Log: $(XSIM_LOG) ==="

# ---------------------------------------------------------------------------
# ref — build and run the C golden-vector generator
# ---------------------------------------------------------------------------
ref:
	@echo ">>> Building C reference..."
	gcc -O2 -Wall -o $(SW_DIR)/murmurhash3_ref $(SW_DIR)/murmurhash3_ref.c
	@echo ">>> Running C reference..."
	$(SW_DIR)/murmurhash3_ref

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------
$(LOG_DIR):
	mkdir -p $(LOG_DIR)

# ---------------------------------------------------------------------------
# clean
# ---------------------------------------------------------------------------
clean:
	@echo ">>> Cleaning generated files..."
	rm -rf xsim.dir .Xil *.pb *.log *.jou webtalk* xvlog.* xelab.*
	rm -rf $(LOG_DIR)/*.log $(LOG_DIR)/*.jou
	rm -f $(SW_DIR)/murmurhash3_ref
	@echo ">>> Done."
