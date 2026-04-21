#!/usr/bin/env python3
"""
analysis.py  —  Parse simulation + Vivado reports, generate paper-quality plots.

Usage:
    python3 scripts/analysis.py [--results-dir PATH] [--vivado-rpt-dir PATH]

Reads:
    results/throughput.csv          (from run_sweep.sh)
    results/cpu_baseline.txt        (from run_sweep.sh)
    vivado/reports/power_N*.rpt     (from Vivado scaling study)
    vivado/reports/utilization_N*.rpt

Outputs:
    results/fig_throughput.png
    results/fig_efficiency.png
    results/fig_area.png
    results/summary_table.txt

All lane counts: N in {1, 2, 4, 8, 16, 32}
"""

import argparse
import csv
import os
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# --------------------------------------------------------------------------
# Try to import matplotlib; print guidance if missing
# --------------------------------------------------------------------------
try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker
    HAS_PLOT = True
except ImportError:
    HAS_PLOT = False
    print("[analysis] matplotlib not found — install with:  pip install matplotlib")
    print("[analysis] Continuing with text-only summary.\n")

REPO = Path(__file__).resolve().parent.parent


# ==========================================================================
# Parsers
# ==========================================================================

def parse_throughput_csv(path: Path) -> Dict[int, Dict[int, float]]:
    """Returns { N: { duty_pct: hashes_per_cycle } }"""
    data: Dict[int, Dict[int, float]] = {}
    if not path.exists():
        print("[WARN] {} not found — skipping throughput data".format(path))
        return data
    with path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            n    = int(row["N"])
            duty = int(row["duty_pct"])
            hpc  = float(row["hashes_per_cycle"])
            data.setdefault(n, {})[duty] = hpc
    return data


def parse_cpu_baseline(path: Path) -> Dict[str, Dict[str, float]]:
    """Returns { "scalar": {"mhps": float, "hpj": float}, ... }"""
    data: Dict[str, Dict[str, float]] = {}
    if not path.exists():
        print("[WARN] {} not found — skipping CPU baseline".format(path))
        return data
    pattern = re.compile(
        r"CPU_RESULT\s+impl=(\S+)\s+n_keys=(\d+)\s+elapsed_s=(\S+)\s+"
        r"throughput_mhps=(\S+)\s+stddev_mhps=(\S+)\s+hashpj=(\S+)"
    )
    with path.open() as f:
        for line in f:
            m = pattern.search(line)
            if m:
                impl  = m.group(1)
                mhps  = float(m.group(4))
                hpj   = float(m.group(6))
                if mhps > 0:
                    data[impl] = {"mhps": mhps, "hpj": hpj}
    return data


def parse_vivado_power(rpt_dir: Path, n: int) -> Optional[float]:
    """Parse total on-chip power (W) from Vivado power report."""
    path = rpt_dir / "power_N{}.rpt".format(n)
    if not path.exists():
        return None
    pattern = re.compile(r"Total\s+On-Chip\s+Power\s*\(W\)\s*\|\s*([\d.]+)")
    with path.open() as f:
        for line in f:
            m = pattern.search(line)
            if m:
                return float(m.group(1))
    return None


def parse_vivado_utilization(rpt_dir: Path, n: int) -> Optional[Dict[str, int]]:
    """Parse LUT/FF/DSP counts from Vivado utilization report."""
    path = rpt_dir / "utilization_N{}.rpt".format(n)
    if not path.exists():
        return None
    result: Dict[str, int] = {}
    patterns = {
        "luts":  re.compile(r"^\|\s*Slice LUTs\s*\|\s*(\d+)"),
        "ffs":   re.compile(r"^\|\s*Slice Registers\s*\|\s*(\d+)"),
        "dsps":  re.compile(r"^\|\s*DSPs\s*\|\s*(\d+)"),
        "brams": re.compile(r"^\|\s*Block RAM Tile\s*\|\s*(\d+)"),
    }
    with path.open() as f:
        for line in f:
            for key, pat in patterns.items():
                if key not in result:
                    m = pat.match(line)
                    if m:
                        result[key] = int(m.group(1))
    return result if result else None


# ==========================================================================
# Plot helpers
# ==========================================================================

LANE_COUNTS = [1, 2, 4, 8, 16, 32]
DUTY_COLORS = {100: "#1f77b4", 75: "#ff7f0e", 50: "#2ca02c", 25: "#d62728"}
MARKERS     = {100: "o",       75: "s",       50: "^",       25: "D"}


def fig_throughput(tp_data: dict, cpu_data: dict, out_path: Path) -> None:
    if not HAS_PLOT:
        return
    fig, ax = plt.subplots(figsize=(7, 5))

    for duty in [100, 75, 50, 25]:
        xs, ys = [], []
        for n in LANE_COUNTS:
            if n in tp_data and duty in tp_data[n]:
                xs.append(n)
                ys.append(tp_data[n][duty])
        if xs:
            ax.plot(xs, ys, marker=MARKERS[duty], color=DUTY_COLORS[duty],
                    linewidth=1.8, markersize=7, label=f"FPGA {duty}% duty")

    # Ideal linear reference
    ax.plot(LANE_COUNTS, LANE_COUNTS, "k--", linewidth=1, alpha=0.4, label="Ideal linear")

    # CPU horizontal lines (convert Mhash/s @ 100 MHz equivalent)
    # For comparison: CPU throughput as "equivalent lanes" at 100 MHz
    CLK_HZ = 100e6
    for impl, vals in cpu_data.items():
        eq_lanes = vals["mhps"] * 1e6 / CLK_HZ
        label = "Scalar C" if "scalar" in impl else "AVX2 ×8"
        ax.axhline(eq_lanes, linestyle=":", linewidth=1.5, alpha=0.7,
                   label=f"CPU {label} equiv. ({eq_lanes:.2f} hashes/cycle)")

    ax.set_xscale("log", base=2)
    ax.set_yscale("log", base=2)
    ax.xaxis.set_major_formatter(ticker.ScalarFormatter())
    ax.yaxis.set_major_formatter(ticker.ScalarFormatter())
    ax.set_xticks(LANE_COUNTS)
    ax.set_xlabel("Number of Lanes (N)")
    ax.set_ylabel("Throughput (hashes / cycle)")
    ax.set_title("MurmurHash3 Accelerator — Throughput Scaling")
    ax.legend(fontsize=8, loc="upper left")
    ax.grid(True, which="both", alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"[plot] {out_path}")


def fig_efficiency(tp_data: dict, cpu_data: dict,
                   rpt_dir: Path, out_path: Path) -> None:
    if not HAS_PLOT:
        return

    CLK_HZ = 100e6   # 100 MHz

    fig, ax = plt.subplots(figsize=(7, 5))

    # FPGA efficiency: (hashes/cycle * CLK_HZ) / power_W
    xs_fpga, ys_fpga = [], []
    for n in LANE_COUNTS:
        power = parse_vivado_power(rpt_dir, n)
        if power is None or power == 0:
            continue
        if n in tp_data and 100 in tp_data[n]:
            hpc = tp_data[n][100]
            hpj = hpc * CLK_HZ / power
            xs_fpga.append(n)
            ys_fpga.append(hpj / 1e6)   # Mhash/J

    if xs_fpga:
        ax.plot(xs_fpga, ys_fpga, marker="o", color="#1f77b4",
                linewidth=2, markersize=8, label="FPGA (100% duty)")

    # CPU horizontal lines
    for impl, vals in cpu_data.items():
        hpj_m = vals["hpj"] / 1e6   # Mhash/J
        label = "Scalar C" if "scalar" in impl else "AVX2 ×8"
        ax.axhline(hpj_m, linestyle=":", linewidth=1.5, alpha=0.7,
                   label=f"CPU {label} ({hpj_m:.1f} Mhash/J, TDP upper bound)")

    if not xs_fpga:
        ax.text(0.5, 0.5, "No Vivado power data available.\nRun: make synth",
                ha="center", va="center", transform=ax.transAxes, fontsize=11,
                color="gray")

    ax.set_xscale("log", base=2)
    ax.xaxis.set_major_formatter(ticker.ScalarFormatter())
    ax.set_xticks(LANE_COUNTS)
    ax.set_xlabel("Number of Lanes (N)")
    ax.set_ylabel("Energy Efficiency (Mhash / J)")
    ax.set_title("MurmurHash3 Accelerator — Energy Efficiency vs. Lane Count")
    ax.legend(fontsize=8)
    ax.grid(True, which="both", alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"[plot] {out_path}")


def fig_area(rpt_dir: Path, out_path: Path) -> None:
    if not HAS_PLOT:
        return

    xs, luts_ys, ffs_ys, dsps_ys = [], [], [], []
    for n in LANE_COUNTS:
        util = parse_vivado_utilization(rpt_dir, n)
        if util:
            xs.append(n)
            luts_ys.append(util.get("luts", 0))
            ffs_ys.append(util.get("ffs", 0))
            dsps_ys.append(util.get("dsps", 0))

    if not xs:
        print("[plot] Skipping area plot — no utilization reports found")
        return

    fig, ax = plt.subplots(figsize=(7, 5))
    ax.plot(xs, luts_ys, marker="o", label="LUTs")
    ax.plot(xs, ffs_ys,  marker="s", label="FFs")
    ax.plot(xs, dsps_ys, marker="^", label="DSPs")
    ax.set_xscale("log", base=2)
    ax.xaxis.set_major_formatter(ticker.ScalarFormatter())
    ax.set_xticks(xs)
    ax.set_xlabel("Number of Lanes (N)")
    ax.set_ylabel("Resource Count")
    ax.set_title("MurmurHash3 Accelerator — Area Scaling (Artix-7)")
    ax.legend()
    ax.grid(True, which="both", alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"[plot] {out_path}")


def print_summary(tp_data: dict, cpu_data: dict, rpt_dir: Path,
                  out_path: Path) -> None:
    CLK_HZ = 100e6
    lines = []
    lines.append("=" * 72)
    lines.append("  MurmurHash3 Accelerator — Summary Table")
    lines.append("=" * 72)

    # Throughput table
    lines.append("")
    lines.append("  FPGA Throughput (hashes/cycle @ 100 MHz)")
    lines.append(f"  {'N':>4}  {'100%':>8}  {'75%':>8}  {'50%':>8}  {'25%':>8}  {'Power(W)':>10}  {'Mhash/J':>10}")
    lines.append("  " + "-" * 68)
    for n in LANE_COUNTS:
        power = parse_vivado_power(rpt_dir, n)
        pw_str = f"{power:.3f}" if power else "N/A"
        d = tp_data.get(n, {})
        hpc100 = d.get(100, float("nan"))
        hpj_str = ""
        if power and not (hpc100 != hpc100):  # not nan
            hpj = hpc100 * CLK_HZ / power / 1e6
            hpj_str = f"{hpj:.2f}"
        lines.append(
            f"  {n:>4}  {d.get(100,'N/A'):>8}  {d.get(75,'N/A'):>8}"
            f"  {d.get(50,'N/A'):>8}  {d.get(25,'N/A'):>8}"
            f"  {pw_str:>10}  {hpj_str or 'N/A':>10}"
        )

    # CPU baselines
    lines.append("")
    lines.append("  CPU Baselines (10M keys)")
    lines.append(f"  {'Impl':>10}  {'Mhash/s':>10}  {'equiv_hpc@100MHz':>18}  {'Mhash/J (TDP UB)':>18}")
    lines.append("  " + "-" * 62)
    for impl, vals in cpu_data.items():
        eq = vals["mhps"] * 1e6 / CLK_HZ
        lines.append(
            f"  {impl:>10}  {vals['mhps']:>10.2f}  {eq:>18.4f}  {vals['hpj']/1e6:>18.4f}"
        )

    lines.append("")
    lines.append("=" * 72)

    text = "\n".join(lines)
    print(text)
    out_path.write_text(text)
    print(f"[summary] {out_path}")


# ==========================================================================
# Main
# ==========================================================================

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results-dir", default=str(REPO / "results"))
    parser.add_argument("--vivado-rpt-dir", default=str(REPO / "vivado" / "reports"))
    args = parser.parse_args()

    results_dir = Path(args.results_dir)
    rpt_dir     = Path(args.vivado_rpt_dir)
    results_dir.mkdir(exist_ok=True)

    tp_data  = parse_throughput_csv(results_dir / "throughput.csv")
    cpu_data = parse_cpu_baseline(results_dir / "cpu_baseline.txt")

    if not tp_data:
        print("[INFO] No throughput data found. Run:  bash scripts/run_sweep.sh")
    if not cpu_data:
        print("[INFO] No CPU baseline found. Run:     bash scripts/run_sweep.sh")

    fig_throughput(tp_data, cpu_data, results_dir / "fig_throughput.png")
    fig_efficiency(tp_data, cpu_data, rpt_dir,    results_dir / "fig_efficiency.png")
    fig_area(rpt_dir,                             results_dir / "fig_area.png")
    print_summary(tp_data, cpu_data, rpt_dir,     results_dir / "summary_table.txt")


if __name__ == "__main__":
    main()
