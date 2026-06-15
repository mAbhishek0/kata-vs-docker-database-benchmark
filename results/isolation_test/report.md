# Isolation Test — Docker TPS Variance Root Cause Analysis

**Date:** 2026-05-01 19:18:55
**Kernel:** 6.17.0-22-generic | **Host:** 16 logical CPUs (8C/16T)
**Container:** 4 CPUs | 4096 MiB | Cores 0-3 | tmpfs
**Workload:** sysbench oltp\_read\_write | 4×100000 rows | 4 threads | 60s/run
**Runs per phase:** 4 | **Total runs:** 16
**Saved system state:** THP=madvise | defrag=madvise | NUMA=0

> Container stayed alive across all phases — only host tuning changed.
> MySQL buffer pool state is identical across phases, eliminating warmup confounds.

---

## Phase Comparison Summary

| Phase | Config | Mean TPS | CV | Mean P99 (ms) | Notes |
|-------|--------|---------|-----|----------|-------|
| Baseline | tmpfs, no fixes | 841.71 | 3.9% | 9.73 | |
| H1: THP off + NUMA off | +THP off +NUMA off | 859.86 | 1.1% | 9.39 | |
| H2: CPU isolation + IRQ aff | +CPU isolation +IRQ affinity | 767.91 | 0.5% | 44.37 | |
| H3: Combined (H1+H2) | Combined H1+H2 | 762.87 | 0.4% | 44.37 | |
| Kata+FC (ref) | devmapper, microVM | 646.83 | 0.7% | 10.61 | from previous bench |

---

## Phase 3: Baseline

**Config:** tmpfs, no fixes

| Run | TPS | QPS | P99 (ms) | Max Lat (ms) |
|-----|-----|-----|----------|-------------|
| 1 | 836.03 | 16720.55 | 10.27 | 22.90 |
| 2 | 868.30 | 17366.02 | 8.90 | 17.67 |
| 3 | 872.00 | 17440.06 | 8.90 | 21.72 |
| 4 | 790.51 | 15810.21 | 10.84 | 30.62 |

**TPS:** mean=841.71, stddev=32.70, CV=3.9%
**P99:** mean=9.73, stddev=0.85, CV=8.8%

<details>
<summary>High-Resolution Monitor Summary</summary>

</details>

---

## Phase 4: H1: THP off + NUMA off

**Config:** +THP off +NUMA off

| Run | TPS | QPS | P99 (ms) | Max Lat (ms) |
|-----|-----|-----|----------|-------------|
| 1 | 857.89 | 17157.71 | 9.56 | 19.15 |
| 2 | 846.32 | 16926.32 | 9.73 | 30.81 |
| 3 | 873.84 | 17476.79 | 8.90 | 24.08 |
| 4 | 861.37 | 17227.34 | 9.39 | 18.65 |

**TPS:** mean=859.86, stddev=9.81, CV=1.1%
**P99:** mean=9.39, stddev=0.31, CV=3.3%

<details>
<summary>High-Resolution Monitor Summary</summary>

</details>

---

## Phase 5: H2: CPU isolation + IRQ aff

**Config:** +CPU isolation +IRQ affinity

| Run | TPS | QPS | P99 (ms) | Max Lat (ms) |
|-----|-----|-----|----------|-------------|
| 1 | 771.12 | 15422.31 | 44.98 | 50.78 |
| 2 | 771.17 | 15423.49 | 44.17 | 50.86 |
| 3 | 766.83 | 15336.50 | 44.17 | 51.18 |
| 4 | 762.53 | 15250.51 | 44.17 | 51.96 |

**TPS:** mean=767.91, stddev=3.57, CV=0.5%
**P99:** mean=44.37, stddev=0.35, CV=0.8%

<details>
<summary>High-Resolution Monitor Summary</summary>

</details>

---

## Phase 6: H3: Combined (H1+H2)

**Config:** Combined H1+H2

| Run | TPS | QPS | P99 (ms) | Max Lat (ms) |
|-----|-----|-----|----------|-------------|
| 1 | 762.96 | 15259.15 | 44.17 | 50.51 |
| 2 | 757.32 | 15146.34 | 44.17 | 50.03 |
| 3 | 765.37 | 15307.76 | 44.98 | 50.38 |
| 4 | 765.81 | 15316.19 | 44.17 | 50.05 |

**TPS:** mean=762.87, stddev=3.38, CV=0.4%
**P99:** mean=44.37, stddev=0.35, CV=0.8%

<details>
<summary>High-Resolution Monitor Summary</summary>

</details>

---

## Conclusion

### Variance Attribution

Examine the CV column in the Phase Comparison Summary:

1. **If H1 (THP off) has lower CV than Baseline** → THP compaction is a significant source of jitter
2. **If H2 (CPU isolation) has lower CV than Baseline** → Host daemon CPU contention causes variance
3. **If H3 (Combined) matches Kata+FC's CV** → Docker variance is fully explained by lack of isolation
4. **If none reduce CV significantly** → Variance source is elsewhere (MySQL internals, scheduler, etc.)

### Key Metrics to Compare

- **CV progression:** Baseline → H1 → H2 → H3 → Kata+FC (should converge if thesis is correct)
- **Mean TPS:** Should stay roughly constant (fixes reduce variance, not throughput)
- **Compaction stalls:** H1/H3 should show zero vs. Baseline

