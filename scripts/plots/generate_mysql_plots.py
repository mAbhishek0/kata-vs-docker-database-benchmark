#!/usr/bin/env python3
"""
Generate all MySQL benchmark plots for the SSP Endterm IEEE paper.
Reads raw sysbench output from bench_* directories.

Output files (upload to Overleaf alongside .tex):
  mysql_tps_comparison.png
  mysql_qps_comparison.png
  mysql_latency_profile.png
  mysql_tps_over_time.png
  mysql_vmexit_breakdown.png
  mysql_tps_variability_box.png
  mysql_isolation_cv.png
  mysql_disk_io_correlation.png
"""

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import numpy as np
import os

# -- Global Style --
plt.rcParams.update({
    'font.family': 'serif',
    'font.size': 10,
    'axes.labelsize': 11,
    'axes.titlesize': 12,
    'xtick.labelsize': 9,
    'ytick.labelsize': 9,
    'legend.fontsize': 9,
    'figure.dpi': 300,
    'savefig.dpi': 300,
    'savefig.bbox': 'tight',
    'savefig.pad_inches': 0.15,
    'axes.grid': True,
    'grid.alpha': 0.3,
    'grid.linestyle': '--',
})

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, '..', '..'))
OUTDIR = os.path.join(PROJECT_ROOT, 'paper', 'figures')
os.makedirs(OUTDIR, exist_ok=True)

# Color palette
C_DOCKER_DISK = '#e74c3c'    # red
C_DOCKER_TMPFS = '#3498db'   # blue
C_KATA_FC = '#2ecc71'        # green
C_BASELINE = '#95a5a6'       # grey
C_H1 = '#f39c12'             # orange
C_H2 = '#9b59b6'             # purple
C_H3 = '#1abc9c'             # teal

# -- Data --

# -- Per-run aggregate TPS --
kata_tps = [642.51, 649.60, 651.25, 640.11, 650.68]
docker_disk_tps = [474.08, 281.60, 475.43, 535.52, 479.84]
docker_tmpfs_tps = [835.29, 837.48, 818.03, 877.02, 849.73]

# -- Per-run aggregate QPS --
kata_qps = [12850.15, 12991.95, 13024.97, 12802.21, 13013.51]
docker_disk_qps = [9481.67, 5632.02, 9508.53, 10710.35, 9596.82]
docker_tmpfs_qps = [16705.88, 16749.59, 16360.63, 17540.47, 16994.56]

# -- Latency profiles (from aggregate stats in reports) --
#                     Min     Avg      P99       Max
kata_lat =         [3.24,   6.18,   10.61,    23.52]
docker_tmpfs_lat = [2.82,   4.74,    9.76,    22.55]
docker_disk_lat =  [4.06,   9.36,   41.69,   184.40]

# -- 10s interval TPS: representative run for each environment --
# Kata+FC Run 3 (median run, TPS=651.25)
kata_interval = [664.68, 661.15, 665.49, 642.20, 628.41, 645.63]
# Docker tmpfs Run 1 (median-ish, TPS=835.29)
tmpfs_interval = [808.66, 790.56, 819.85, 806.75, 892.50, 893.50]
# Docker disk Run 1 (shows I/O stalls clearly, TPS=474.08)
disk_interval = [668.42, 403.41, 515.61, 645.27, 296.39, 315.22]
interval_t = [10, 20, 30, 40, 50, 60]

# -- VM-Exit data (aggregated across 5 runs, from report) --
vmexit_labels = ['MSR', 'Interrupt', 'NPF', 'HLT', 'VIntr', 'Other']
vmexit_samples = [7315319, 3728667, 2564910, 2309907, 680972, 29743+111+4]
vmexit_avg_time_us = [5.17, 8.88, 15.79, 110.55, 3.06, 2.30]
vmexit_time_pct = [10.37, 9.16, 11.10, 68.75, 0.59, 0.03]  # Run 1 percentages (Other = hypercall+pause)

# -- Isolation test data --
iso_phases = ['Baseline', 'H1\nTHP off', 'H2\nCPU isol.', 'H3\nCombined', 'Kata+FC\n(ref)']
iso_cv = [3.9, 1.1, 0.5, 0.4, 0.7]
iso_mean_tps = [841.71, 859.86, 767.91, 762.87, 646.83]
iso_mean_p99 = [9.73, 9.39, 44.37, 44.37, 10.61]

# -- Isolation test per-run TPS (for box plot) --
iso_baseline_tps = [836.03, 868.30, 872.00, 790.51]
iso_h1_tps = [857.89, 846.32, 873.84, 861.37]
iso_h2_tps = [771.12, 771.17, 766.83, 762.53]
iso_h3_tps = [762.96, 757.32, 765.37, 765.81]

# -- Docker disk monitor data: Run 2 (worst, TPS=281.60) --
# Extracted disk_util and approx TPS from 10s intervals
disk_monitor_util = [75.30, 84.90, 68.10, 68.70, 67.30, 64.50, 72.90,
                     91.90, 92.20, 90.00, 90.00, 94.10, 92.10, 94.70,
                     93.40, 95.30, 93.50, 91.10]
disk_monitor_tps_approx = [  # approximate from the two 10s intervals
    513, 513, 672, 672, 672, 672, 672,
    118, 118, 118, 118, 76, 76, 76,
    59, 59, 59, 59]


# --- Figure 1: TPS Comparison Bar Chart ---
def plot_tps_comparison():
    fig, ax = plt.subplots(figsize=(3.5, 2.8))
    envs = ['Docker\n(disk)', 'Kata+FC\n(devmapper)', 'Docker\n(tmpfs)']
    means = [np.mean(docker_disk_tps), np.mean(kata_tps), np.mean(docker_tmpfs_tps)]
    stds = [np.std(docker_disk_tps), np.std(kata_tps), np.std(docker_tmpfs_tps)]
    colors = [C_DOCKER_DISK, C_KATA_FC, C_DOCKER_TMPFS]

    bars = ax.bar(envs, means, yerr=stds, capsize=4, color=colors,
                  edgecolor='black', linewidth=0.5, width=0.55, alpha=0.85)
    for bar, m, s in zip(bars, means, stds):
        # Place label above the error-bar cap (bar top + std + small padding)
        ax.text(bar.get_x() + bar.get_width()/2, m + s + 18,
                f'{m:.0f}', ha='center', va='bottom', fontsize=8, fontweight='bold')
    ax.set_ylabel('Transactions Per Second (TPS)')
    ax.set_ylim(0, max(m + s for m, s in zip(means, stds)) * 1.30)
    ax.set_title('MySQL OLTP Throughput')
    fig.tight_layout()
    fig.savefig(os.path.join(OUTDIR, 'mysql_tps_comparison.png'))
    plt.close(fig)
    print("  Saved mysql_tps_comparison.png")


# --- Figure 2: QPS Comparison Bar Chart ---
def plot_qps_comparison():
    fig, ax = plt.subplots(figsize=(3.5, 2.8))
    envs = ['Docker\n(disk)', 'Kata+FC\n(devmapper)', 'Docker\n(tmpfs)']
    means = [np.mean(docker_disk_qps), np.mean(kata_qps), np.mean(docker_tmpfs_qps)]
    stds = [np.std(docker_disk_qps), np.std(kata_qps), np.std(docker_tmpfs_qps)]
    colors = [C_DOCKER_DISK, C_KATA_FC, C_DOCKER_TMPFS]

    bars = ax.bar(envs, means, yerr=stds, capsize=4, color=colors,
                  edgecolor='black', linewidth=0.5, width=0.55, alpha=0.85)
    for bar, m, s in zip(bars, means, stds):
        # Place label above the error-bar cap (bar top + std + small padding)
        ax.text(bar.get_x() + bar.get_width()/2, m + s + 250,
                f'{m:.0f}', ha='center', va='bottom', fontsize=8, fontweight='bold')
    ax.set_ylabel('Queries Per Second (QPS)')
    ax.set_ylim(0, max(m + s for m, s in zip(means, stds)) * 1.30)
    ax.set_title('MySQL OLTP Query Throughput')
    fig.tight_layout()
    fig.savefig(os.path.join(OUTDIR, 'mysql_qps_comparison.png'))
    plt.close(fig)
    print("  Saved mysql_qps_comparison.png")


# --- Figure 3: Latency Profile ---
def plot_latency_profile():
    fig, ax = plt.subplots(figsize=(3.5, 3.0))
    metrics = ['Min', 'Avg', 'P99', 'Max']
    x = np.arange(len(metrics))
    w = 0.25

    ax.bar(x - w, docker_disk_lat, w, label='Docker (disk)', color=C_DOCKER_DISK,
           edgecolor='black', linewidth=0.5, alpha=0.85)
    ax.bar(x,     kata_lat, w, label='Kata+FC', color=C_KATA_FC,
           edgecolor='black', linewidth=0.5, alpha=0.85)
    ax.bar(x + w, docker_tmpfs_lat, w, label='Docker (tmpfs)', color=C_DOCKER_TMPFS,
           edgecolor='black', linewidth=0.5, alpha=0.85)

    ax.set_xticks(x)
    ax.set_xticklabels(metrics)
    ax.set_ylabel('Latency (ms)')
    ax.set_title('MySQL Latency Profile')
    ax.legend(loc='upper left', framealpha=0.9, fontsize=7)

    # Log scale to show Max properly without squishing the rest
    ax.set_yscale('log')
    ax.yaxis.set_major_formatter(mticker.ScalarFormatter())
    ax.yaxis.get_major_formatter().set_scientific(False)
    ax.set_ylim(1, 300)

    fig.tight_layout()
    fig.savefig(os.path.join(OUTDIR, 'mysql_latency_profile.png'))
    plt.close(fig)
    print("  Saved mysql_latency_profile.png")


# --- Figure 4: TPS Over Time ---
def plot_tps_over_time():
    fig, ax = plt.subplots(figsize=(3.5, 2.5))
    ax.plot(interval_t, tmpfs_interval, 's-', color=C_DOCKER_TMPFS,
            label='Docker (tmpfs)', markersize=4, linewidth=1.5)
    ax.plot(interval_t, kata_interval, 'o-', color=C_KATA_FC,
            label='Kata+FC', markersize=4, linewidth=1.5)
    ax.plot(interval_t, disk_interval, '^-', color=C_DOCKER_DISK,
            label='Docker (disk)', markersize=4, linewidth=1.5)

    ax.set_xlabel('Elapsed Time (s)')
    ax.set_ylabel('TPS')
    ax.set_title('TPS Stability Over 60s Run')
    ax.legend(loc='lower left', framealpha=0.9, fontsize=7)
    ax.set_xlim(5, 65)
    ax.set_ylim(0, 1050)
    fig.tight_layout()
    fig.savefig(os.path.join(OUTDIR, 'mysql_tps_over_time.png'))
    plt.close(fig)
    print("  Saved mysql_tps_over_time.png")


# --- Figure 5: VM-Exit Breakdown ---
def plot_vmexit_breakdown():
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(4.0, 3.0), sharey=True)

    y = np.arange(len(vmexit_labels))
    # Left: sample count (log scale)
    pcts = [s / sum(vmexit_samples) * 100 for s in vmexit_samples]
    colors_vm = ['#e74c3c', '#f39c12', '#3498db', '#2ecc71', '#9b59b6', '#95a5a6']

    ax1.barh(y, pcts, color=colors_vm, edgecolor='black', linewidth=0.4, height=0.6)
    ax1.set_xlabel('Sample %')
    ax1.set_title('Exit Frequency', fontsize=9)
    ax1.set_yticks(y)
    ax1.set_yticklabels(vmexit_labels, fontsize=8)
    ax1.set_xlim(0, max(pcts) * 1.45)   # extra room so labels never clip
    for i, p in enumerate(pcts):
        if p > 1:
            ax1.text(p + 0.8, i, f'{p:.1f}%', va='center', fontsize=7)

    # Right: time percentage
    ax2.barh(y, vmexit_time_pct, color=colors_vm, edgecolor='black', linewidth=0.4, height=0.6)
    ax2.set_xlabel('Time %')
    ax2.set_title('Time Consumed', fontsize=9)
    ax2.set_xlim(0, max(vmexit_time_pct) * 1.45)  # extra room so labels never clip
    for i, p in enumerate(vmexit_time_pct):
        if p > 0.5:
            ax2.text(p + 0.8, i, f'{p:.1f}%', va='center', fontsize=7)

    fig.suptitle('VM-Exit Root Cause Analysis (Kata+FC)', fontsize=10, y=0.98)
    fig.tight_layout(rect=[0, 0, 1, 0.93])
    fig.savefig(os.path.join(OUTDIR, 'mysql_vmexit_breakdown.png'))
    plt.close(fig)
    print("  Saved mysql_vmexit_breakdown.png")


# --- Figure 6: TPS Variability Box Plot ---
def plot_tps_variability_box():
    fig, ax = plt.subplots(figsize=(3.5, 3.0))
    data = [docker_disk_tps, kata_tps, docker_tmpfs_tps]
    labels = ['Docker\n(disk)', 'Kata+FC\n(devmapper)', 'Docker\n(tmpfs)']
    colors = [C_DOCKER_DISK, C_KATA_FC, C_DOCKER_TMPFS]

    bp = ax.boxplot(data, labels=labels, patch_artist=True, widths=0.5,
                    medianprops=dict(color='black', linewidth=1.5),
                    whiskerprops=dict(linewidth=1),
                    capprops=dict(linewidth=1))
    for patch, color in zip(bp['boxes'], colors):
        patch.set_facecolor(color)
        patch.set_alpha(0.7)

    # Overlay individual points (seeded for reproducibility)
    rng = np.random.RandomState(42)
    for i, d in enumerate(data, 1):
        x = rng.normal(i, 0.04, len(d))
        ax.scatter(x, d, alpha=0.7, s=20, zorder=5, edgecolors='black', linewidth=0.5,
                   color=colors[i-1])

    # Annotate CV
    cvs = [f'CV={np.std(d)/np.mean(d)*100:.1f}%' for d in data]
    for i, cv in enumerate(cvs, 1):
        ax.text(i, max(data[i-1]) + 25, cv, ha='center', fontsize=7, fontstyle='italic')

    ax.set_ylabel('TPS')
    ax.set_title('TPS Distribution Across 5 Runs')
    ax.set_ylim(200, 960)
    fig.tight_layout()
    fig.savefig(os.path.join(OUTDIR, 'mysql_tps_variability_box.png'))
    plt.close(fig)
    print("  Saved mysql_tps_variability_box.png")


# --- Figure 7: Isolation Test CV Progression ---
def plot_isolation_cv():
    fig, ax1 = plt.subplots(figsize=(3.8, 3.0))
    x = np.arange(len(iso_phases))
    colors_iso = [C_BASELINE, C_H1, C_H2, C_H3, C_KATA_FC]

    bars = ax1.bar(x, iso_cv, color=colors_iso, edgecolor='black',
                   linewidth=0.5, width=0.55, alpha=0.85)
    for bar, cv in zip(bars, iso_cv):
        ax1.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.1,
                 f'{cv}%', ha='center', va='bottom', fontsize=8, fontweight='bold')

    ax1.set_xticks(x)
    ax1.set_xticklabels(iso_phases, fontsize=7)
    ax1.set_ylabel('Coefficient of Variation (%)')
    ax1.set_title('TPS Variance Reduction via Isolation')
    ax1.set_ylim(0, 5.5)

    # Overlay mean TPS as a line on secondary axis
    ax2 = ax1.twinx()
    ax2.plot(x, iso_mean_tps, 'ko--', markersize=4, linewidth=1, label='Mean TPS')
    ax2.set_ylabel('Mean TPS', rotation=270, labelpad=12)
    ax2.set_ylim(500, 1000)
    ax2.legend(loc='upper right', fontsize=7)

    fig.tight_layout()
    fig.savefig(os.path.join(OUTDIR, 'mysql_isolation_cv.png'))
    plt.close(fig)
    print("  Saved mysql_isolation_cv.png")


# --- Figure 8: Disk I/O vs TPS Correlation ---
def plot_disk_io_correlation():
    fig, ax1 = plt.subplots(figsize=(3.8, 2.8))

    t = np.arange(len(disk_monitor_util))
    # Disk utilization on left axis
    ax1.fill_between(t, disk_monitor_util, alpha=0.3, color=C_DOCKER_DISK, label='Disk %util')
    ax1.plot(t, disk_monitor_util, color=C_DOCKER_DISK, linewidth=1)
    ax1.set_xlabel('Sample (~2s intervals)')
    ax1.set_ylabel('Disk Utilization (%)', color=C_DOCKER_DISK)
    ax1.set_ylim(0, 100)
    ax1.tick_params(axis='y', labelcolor=C_DOCKER_DISK)

    # TPS on right axis
    ax2 = ax1.twinx()
    ax2.plot(t, disk_monitor_tps_approx, 's-', color='#2c3e50', markersize=3,
             linewidth=1.2, label='Approx TPS')
    ax2.set_ylabel('TPS (approx)', color='#2c3e50', rotation=270, labelpad=12)
    ax2.set_ylim(0, 800)
    ax2.tick_params(axis='y', labelcolor='#2c3e50')

    ax1.set_title('Docker (disk): I/O Saturation vs TPS Collapse')

    # Combined legend
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc='lower left', fontsize=7)

    fig.tight_layout()
    fig.savefig(os.path.join(OUTDIR, 'mysql_disk_io_correlation.png'))
    plt.close(fig)
    print("  Saved mysql_disk_io_correlation.png")


# --- Main ---
if __name__ == '__main__':
    print(f"Generating plots in: {OUTDIR}")
    plot_tps_comparison()        # extra (not in paper, but useful)
    plot_qps_comparison()        # extra
    plot_latency_profile()       # extra
    plot_tps_over_time()         # extra
    plot_vmexit_breakdown()      # IN PAPER
    plot_tps_variability_box()   # IN PAPER
    plot_isolation_cv()          # IN PAPER
    # plot_disk_io_correlation() # removed from paper
    print(f"\nDone! Plots generated. Upload mysql_vmexit_breakdown.png,")
    print(f"mysql_tps_variability_box.png, mysql_isolation_cv.png to Overleaf.")

