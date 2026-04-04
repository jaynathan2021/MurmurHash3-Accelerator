# =============================================================================
# Makefile — MurmurHash3 Accelerator
#
# Targets:
#   sim        Run Vivado xsim simulation (default)
#   sim-N=<n>  Run simulation with N lanes (e.g., make sim N=8)
#   ref        Build and run C reference to print golden vectors
#   synth      Run Vivado scaling study (N=1,2,4,8) — long, needs Vivado
#   clean      Remove all generated files
#
# Requirements:
#   - Vivado 2022+ on PATH  (for sim / synth targets)
#   - gcc                   (for ref target)
#
# Usage from repo root:
#   make -f scripts/Makefile sim
#   make -f scripts/Makefile sim N=8
#   make -f scripts/Makefile ref
#   make -f scripts/Makefile synth
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
N        ?= 4                     # number of parallel lanes for simulation
TAG_W    ?= 8

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
.PHONY: all sim ref synth clean

all: sim

# ---------------------------------------------------------------------------
# sim — compile, elaborate, simulate using Vivado xsim
#
# xvlog compiles all .sv files into the xsim work library.
# xelab links the snapshot; -generic_top overrides N and TAG_W so you can
#   run "make sim N=8" without editing the testbench.
# xsim runs the snapshot until $finish.
# ---------------------------------------------------------------------------
sim: | $(LOG_DIR)
	@echo ">>> [1/3] Compiling RTL + testbench (N=$(N) TAG_W=$(TAG_W))..."
	$(XVLOG) --sv --work work \
	    $(RTL_SRCS) $(TB_SRCS) \
	    2>&1 | tee $(XVLOG_LOG)

	@echo ">>> [2/3] Elaborating $(SNAP)..."
	$(XELAB) --sv \
	    --snapshot $(SNAP) \
	    --debug typical \
	    --generic_top "N=$(N)" \
	    --generic_top "TAG_W=$(TAG_W)" \
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
# synth — run the Vivado scaling study (N=1,2,4,8, full implementation)
#
# This can take 30–60 minutes depending on the machine.
# Reports land in vivado/reports/.
# ---------------------------------------------------------------------------
synth:
	@echo ">>> Running Vivado scaling study (N=1,2,4,8)..."
	vivado -mode batch \
	    -source $(REPO)/vivado/run_scaling_study.tcl \
	    -log    $(LOG_DIR)/vivado_scaling.log \
	    -journal $(LOG_DIR)/vivado_scaling.jou

	@echo ""
	@echo "=== Synthesis complete. Reports in $(REPO)/vivado/reports/ ==="

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
