# =============================================================================
# nexys_a4.xdc
#
# Timing and I/O constraints for the MurmurHash3 accelerator on Nexys A4.
# Target device : Xilinx Artix-7  xc7a100tcsg324-1
# Board         : Digilent Nexys A4
#
# For the scaling study (synthesis + implementation only, no board pinout),
# only the clock constraint is strictly required.  The I/O pin assignments
# are included for completeness if a board-level test is desired.
#
# Usage in run_scaling_study.tcl:
#   add_files -fileset constrs_1 constraints/nexys_a4.xdc
# =============================================================================

# -----------------------------------------------------------------------------
# Primary clock — 100 MHz onboard oscillator
# Nexys A4 schematic: W5 (E3 on xc7a100t package)
# -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -period 10.000 -name sys_clk_pin -waveform {0.000 5.000} [get_ports clk]

# -----------------------------------------------------------------------------
# Reset — connected to CPU_RESETN (active-low pushbutton, center)
# Nexys A4: pin C12
# -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN C12 IOSTANDARD LVCMOS33 } [get_ports rst_n]

# -----------------------------------------------------------------------------
# Timing exceptions
# -----------------------------------------------------------------------------
# All register outputs that are not consumed on the board are false paths for
# synthesis-only / utilization runs.  Comment these out if you add real I/O.
set_false_path -from [get_ports rst_n]

# -----------------------------------------------------------------------------
# Bitstream configuration (recommended for Artix-7 on Nexys A4)
# -----------------------------------------------------------------------------
set_property CFGBVS         VCCO [current_design]
set_property CONFIG_VOLTAGE  3.3  [current_design]

# -----------------------------------------------------------------------------
# Note: valid_in, key_in, seed_in, tag_in, valid_out, hash_out, tag_out
# are internal signals in the scaling study (no board I/O assignment).
# If you wish to expose them via PMOD or UART, add pin assignments here.
# -----------------------------------------------------------------------------
