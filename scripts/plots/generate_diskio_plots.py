#!/usr/bin/env python3
"""
Generate disk I/O benchmark plots for the SSP Endterm IEEE paper.
Reads CSV results from bench_diskio_* directory.

Output files:
  diskio_bw_comparison.png       – Bandwidth grouped bar (4 I/O types × 4 block sizes)
  diskio_latency_comparison.png  – Mean latency grouped bar
  diskio_iops_comparison.png     – IOPS grouped bar
  diskio_randwrite_deep_dive.png – Random write BW + latency side-by-side
  diskio_vmexit_heatmap.png      – VM-exit count heatmap (block size × I/O type)
  diskio_latency_variability.png – CV comparison showing Docker write instability
"""

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import numpy as np
import pandas as pd
import os
import glob

# -- Global Style (matches generate_mysql_plots.py) --
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

# Color palette (matching MySQL plots)
C_DOCKER = '#e74c3c'     # red
C_KATA_FC = '#2ecc71'    # green

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, '..', '..'))
OUTDIR = os.path.join(PROJECT_ROOT, 'paper', 'figures')
os.makedirs(OUTDIR, exist_ok=True)

# -- Locate data --
DATA_DIR = os.path.join(PROJECT_ROOT, 'results', 'disk_io')
print(f"Reading data from: {DATA_DIR}")

kata_df = pd.read_csv(os.path.join(DATA_DIR, 'kata_results.csv'))
docker_df = pd.read_csv(os.path.join(DATA_DIR, 'docker_results.csv'))

# Convert bandwidth from KiB/s to MiB/s
kata_df['bw_mib'] = kata_df['bw_kib'] / 1024.0
docker_df['bw_mib'] = docker_df['bw_kib'] / 1024.0

BLOCK_SIZES = ['16k', '64k', '256k', '1m']
IO_TYPES = ['read', 'write', 'randread', 'randwrite']
IO_LABELS = {'read': 'Seq Read', 'write': 'Seq Write',
             'randread': 'Rand Read', 'randwrite': 'Rand Write'}


def get_mean_std(df, bs, rw, col):
    """Return (mean, std) for a given block size and rw type."""
    subset = df[(df['bs'] == bs) & (df['rw'] == rw)][col]
    return subset.mean(), subset.std()


def add_value_labels(ax, bars, fmt='{:.0f}', fontsize=7, offset=0):
    """Add value labels on top of bars."""
    for bar in bars:
        height = bar.get_height()
        if height > 0:
            ax.text(bar.get_x() + bar.get_width() / 2., height + offset,
                    fmt.format(height), ha='center', va='bottom',
                    fontsize=fontsize, fontweight='bold')


# --- Plot 1: Bandwidth Comparison ---
def plot_bandwidth():
    fig, axes = plt.subplots(2, 2, figsize=(10, 8))
    fig.suptitle('Disk I/O Bandwidth: Kata+FC vs Docker', fontsize=14, fontweight='bold', y=1.02)

    for idx, rw in enumerate(IO_TYPES):
        ax = axes[idx // 2][idx % 2]
        kata_means, kata_stds = [], []
        docker_means, docker_stds = [], []

        for bs in BLOCK_SIZES:
            km, ks = get_mean_std(kata_df, bs, rw, 'bw_mib')
            dm, ds = get_mean_std(docker_df, bs, rw, 'bw_mib')
            kata_means.append(km)
            kata_stds.append(ks)
            docker_means.append(dm)
            docker_stds.append(ds)

        x = np.arange(len(BLOCK_SIZES))
        w = 0.35

        bars1 = ax.bar(x - w/2, kata_means, w, yerr=kata_stds,
                        label='Kata+FC', color=C_KATA_FC, edgecolor='white',
                        capsize=3, alpha=0.9)
        bars2 = ax.bar(x + w/2, docker_means, w, yerr=docker_stds,
                        label='Docker', color=C_DOCKER, edgecolor='white',
                        capsize=3, alpha=0.9)

        ax.set_title(IO_LABELS[rw], fontweight='bold')
        ax.set_xlabel('Block Size')
        ax.set_ylabel('Bandwidth (MiB/s)')
        ax.set_xticks(x)
        ax.set_xticklabels(BLOCK_SIZES)
        ax.legend(loc='best', framealpha=0.9)
        ax.set_ylim(bottom=0)

    fig.tight_layout()
    path = os.path.join(OUTDIR, 'diskio_bw_comparison.png')
    fig.savefig(path)
    print(f"Saved: {path}")
    plt.close(fig)


# --- Plot 2: Latency Comparison ---
def plot_latency():
    fig, axes = plt.subplots(2, 2, figsize=(10, 8))
    fig.suptitle('Disk I/O Latency: Kata+FC vs Docker', fontsize=14, fontweight='bold', y=1.02)

    for idx, rw in enumerate(IO_TYPES):
        ax = axes[idx // 2][idx % 2]
        kata_means, docker_means = [], []

        for bs in BLOCK_SIZES:
            km, _ = get_mean_std(kata_df, bs, rw, 'lat_mean_us')
            dm, _ = get_mean_std(docker_df, bs, rw, 'lat_mean_us')
            kata_means.append(km)
            docker_means.append(dm)

        x = np.arange(len(BLOCK_SIZES))
        w = 0.35

        bars1 = ax.bar(x - w/2, kata_means, w,
                        label='Kata+FC', color=C_KATA_FC, edgecolor='white', alpha=0.9)
        bars2 = ax.bar(x + w/2, docker_means, w,
                        label='Docker', color=C_DOCKER, edgecolor='white', alpha=0.9)

        ax.set_title(IO_LABELS[rw], fontweight='bold')
        ax.set_xlabel('Block Size')
        ax.set_ylabel('Mean Latency (μs)')
        ax.set_xticks(x)
        ax.set_xticklabels(BLOCK_SIZES)
        ax.set_yscale('log')
        ax.legend(loc='best', framealpha=0.9)

        # Add value labels
        for bar in list(bars1) + list(bars2):
            h = bar.get_height()
            if h > 0:
                label = f'{h:.0f}' if h >= 100 else f'{h:.1f}'
                ax.text(bar.get_x() + bar.get_width()/2., h * 1.15,
                        label, ha='center', va='bottom', fontsize=6.5, fontweight='bold')

    fig.tight_layout()
    path = os.path.join(OUTDIR, 'diskio_latency_comparison.png')
    fig.savefig(path)
    print(f"Saved: {path}")
    plt.close(fig)


# --- Plot 3: IOPS Comparison ---
def plot_iops():
    fig, axes = plt.subplots(2, 2, figsize=(10, 8))
    fig.suptitle('Disk I/O IOPS: Kata+FC vs Docker', fontsize=14, fontweight='bold', y=1.02)

    for idx, rw in enumerate(IO_TYPES):
        ax = axes[idx // 2][idx % 2]
        kata_means, kata_stds = [], []
        docker_means, docker_stds = [], []

        for bs in BLOCK_SIZES:
            km, ks = get_mean_std(kata_df, bs, rw, 'iops')
            dm, ds = get_mean_std(docker_df, bs, rw, 'iops')
            kata_means.append(km)
            kata_stds.append(ks)
            docker_means.append(dm)
            docker_stds.append(ds)

        x = np.arange(len(BLOCK_SIZES))
        w = 0.35

        bars1 = ax.bar(x - w/2, kata_means, w, yerr=kata_stds,
                        label='Kata+FC', color=C_KATA_FC, edgecolor='white',
                        capsize=3, alpha=0.9)
        bars2 = ax.bar(x + w/2, docker_means, w, yerr=docker_stds,
                        label='Docker', color=C_DOCKER, edgecolor='white',
                        capsize=3, alpha=0.9)

        ax.set_title(IO_LABELS[rw], fontweight='bold')
        ax.set_xlabel('Block Size')
        ax.set_ylabel('IOPS')
        ax.set_xticks(x)
        ax.set_xticklabels(BLOCK_SIZES)
        ax.legend(loc='best', framealpha=0.9)
        ax.set_ylim(bottom=0)

    fig.tight_layout()
    path = os.path.join(OUTDIR, 'diskio_iops_comparison.png')
    fig.savefig(path)
    print(f"Saved: {path}")
    plt.close(fig)


# --- Plot 4: Random Write Deep Dive ---
def plot_randwrite_deep_dive():
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 5))
    fig.suptitle('Random Write Deep Dive: Kata+FC vs Docker',
                 fontsize=14, fontweight='bold', y=1.02)

    rw = 'randwrite'
    kata_bw, docker_bw = [], []
    kata_lat, docker_lat = [], []
    kata_bw_std, docker_bw_std = [], []
    kata_lat_std, docker_lat_std = [], []

    for bs in BLOCK_SIZES:
        km, ks = get_mean_std(kata_df, bs, rw, 'bw_mib')
        dm, ds = get_mean_std(docker_df, bs, rw, 'bw_mib')
        kata_bw.append(km); kata_bw_std.append(ks)
        docker_bw.append(dm); docker_bw_std.append(ds)

        km, ks = get_mean_std(kata_df, bs, rw, 'lat_mean_us')
        dm, ds = get_mean_std(docker_df, bs, rw, 'lat_mean_us')
        kata_lat.append(km); kata_lat_std.append(ks)
        docker_lat.append(dm); docker_lat_std.append(ds)

    x = np.arange(len(BLOCK_SIZES))
    w = 0.35

    # Left: Bandwidth
    b1 = ax1.bar(x - w/2, kata_bw, w, yerr=kata_bw_std,
                  label='Kata+FC', color=C_KATA_FC, edgecolor='white', capsize=4, alpha=0.9)
    b2 = ax1.bar(x + w/2, docker_bw, w, yerr=docker_bw_std,
                  label='Docker', color=C_DOCKER, edgecolor='white', capsize=4, alpha=0.9)

    # Add Δ% annotations
    for i in range(len(BLOCK_SIZES)):
        if docker_bw[i] > 0:
            delta = (kata_bw[i] - docker_bw[i]) / docker_bw[i] * 100
            max_h = max(kata_bw[i] + kata_bw_std[i], docker_bw[i] + docker_bw_std[i])
            ax1.annotate(f'+{delta:.0f}%', xy=(x[i], max_h),
                         fontsize=8, fontweight='bold', ha='center', va='bottom',
                         color='#27ae60')

    ax1.set_title('Bandwidth', fontweight='bold')
    ax1.set_xlabel('Block Size')
    ax1.set_ylabel('Bandwidth (MiB/s)')
    ax1.set_xticks(x)
    ax1.set_xticklabels(BLOCK_SIZES)
    ax1.legend(loc='upper left', framealpha=0.9)
    ax1.set_ylim(bottom=0)

    # Right: Latency (log scale)
    b3 = ax2.bar(x - w/2, kata_lat, w, yerr=kata_lat_std,
                  label='Kata+FC', color=C_KATA_FC, edgecolor='white', capsize=4, alpha=0.9)
    b4 = ax2.bar(x + w/2, docker_lat, w, yerr=docker_lat_std,
                  label='Docker', color=C_DOCKER, edgecolor='white', capsize=4, alpha=0.9)

    ax2.set_title('Mean Latency', fontweight='bold')
    ax2.set_xlabel('Block Size')
    ax2.set_ylabel('Latency (μs)')
    ax2.set_xticks(x)
    ax2.set_xticklabels(BLOCK_SIZES)
    ax2.set_yscale('log')
    ax2.legend(loc='upper left', framealpha=0.9)

    fig.tight_layout()
    path = os.path.join(OUTDIR, 'diskio_randwrite_deep_dive.png')
    fig.savefig(path)
    print(f"Saved: {path}")
    plt.close(fig)


# --- Plot 5: VM-Exit Heatmap ---
def plot_vmexit_heatmap():
    fig, ax = plt.subplots(figsize=(7, 5))

    # Build matrix: rows = block sizes, cols = I/O types
    matrix = np.zeros((len(BLOCK_SIZES), len(IO_TYPES)))
    for i, bs in enumerate(BLOCK_SIZES):
        for j, rw in enumerate(IO_TYPES):
            subset = kata_df[(kata_df['bs'] == bs) & (kata_df['rw'] == rw)]['vm_exits']
            matrix[i, j] = subset.mean()

    im = ax.imshow(matrix, cmap='YlOrRd', aspect='auto', interpolation='nearest')

    # Labels
    ax.set_xticks(range(len(IO_TYPES)))
    ax.set_xticklabels([IO_LABELS[t] for t in IO_TYPES], fontweight='bold')
    ax.set_yticks(range(len(BLOCK_SIZES)))
    ax.set_yticklabels(BLOCK_SIZES, fontweight='bold')
    ax.set_xlabel('I/O Type')
    ax.set_ylabel('Block Size')
    ax.set_title('VM Exits per fio Test (Kata+FC, 20s runs)',
                 fontsize=13, fontweight='bold')

    # Annotate cells
    for i in range(len(BLOCK_SIZES)):
        for j in range(len(IO_TYPES)):
            val = matrix[i, j]
            # Choose text color based on background
            text_color = 'white' if val > matrix.max() * 0.6 else 'black'
            ax.text(j, i, f'{val/1000:.0f}K', ha='center', va='center',
                    fontsize=10, fontweight='bold', color=text_color)

    cbar = fig.colorbar(im, ax=ax, shrink=0.8, label='VM Exits')
    cbar.ax.yaxis.set_major_formatter(mticker.FuncFormatter(
        lambda x, _: f'{x/1e6:.1f}M' if x >= 1e6 else f'{x/1e3:.0f}K'))

    fig.tight_layout()
    path = os.path.join(OUTDIR, 'diskio_vmexit_heatmap.png')
    fig.savefig(path)
    print(f"Saved: {path}")
    plt.close(fig)


# --- Plot 6: Latency Variability ---
def plot_latency_variability():
    fig, ax = plt.subplots(figsize=(10, 6))

    # Compute CV for each (bs, rw) pair for both environments
    labels = []
    kata_cvs = []
    docker_cvs = []

    for rw in IO_TYPES:
        for bs in BLOCK_SIZES:
            # Kata CV
            k_sub = kata_df[(kata_df['bs'] == bs) & (kata_df['rw'] == rw)]['lat_mean_us']
            k_cv = (k_sub.std() / k_sub.mean() * 100) if k_sub.mean() > 0 else 0

            # Docker CV
            d_sub = docker_df[(docker_df['bs'] == bs) & (docker_df['rw'] == rw)]['lat_mean_us']
            d_cv = (d_sub.std() / d_sub.mean() * 100) if d_sub.mean() > 0 else 0

            labels.append(f'{IO_LABELS[rw]}\n{bs}')
            kata_cvs.append(k_cv)
            docker_cvs.append(d_cv)

    x = np.arange(len(labels))
    w = 0.35

    bars1 = ax.bar(x - w/2, kata_cvs, w, label='Kata+FC', color=C_KATA_FC,
                    edgecolor='white', alpha=0.9)
    bars2 = ax.bar(x + w/2, docker_cvs, w, label='Docker', color=C_DOCKER,
                    edgecolor='white', alpha=0.9)

    ax.set_title('Latency Coefficient of Variation (CV%) - Inter-Run Variability',
                 fontsize=13, fontweight='bold')
    ax.set_xlabel('I/O Pattern & Block Size')
    ax.set_ylabel('CV (%)')
    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontsize=7)
    ax.legend(loc='upper left', framealpha=0.9)

    # Add thin vertical separators between I/O types
    for i in range(1, len(IO_TYPES)):
        ax.axvline(x=i * len(BLOCK_SIZES) - 0.5, color='grey', linestyle=':',
                   linewidth=0.8, alpha=0.5)

    # Highlight the worst Docker cases
    max_docker_cv = max(docker_cvs)
    for i, cv in enumerate(docker_cvs):
        if cv > 50:
            ax.annotate(f'{cv:.0f}%', xy=(x[i] + w/2, cv),
                        fontsize=7, fontweight='bold', ha='center', va='bottom',
                        color=C_DOCKER)

    fig.tight_layout()
    path = os.path.join(OUTDIR, 'diskio_latency_variability.png')
    fig.savefig(path)
    print(f"Saved: {path}")
    plt.close(fig)


# --- Main ---
if __name__ == '__main__':
    print("Generating disk I/O benchmark plots...")
    plot_bandwidth()
    plot_latency()
    plot_iops()
    plot_randwrite_deep_dive()
    plot_vmexit_heatmap()
    plot_latency_variability()
    print("\nAll plots generated successfully!")
