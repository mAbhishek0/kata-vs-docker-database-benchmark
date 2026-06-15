# MySQL OLTP Benchmark — Kata + Firecracker

**Date:** 2026-05-01 13:39:34
**Kernel:** 6.17.0-22-generic | **Host CPUs:** 16
**VM Resources:** 4 vCPUs | 4096 MiB RAM | Pinned to cores 0-3
**Workload:** sysbench oltp\_read\_write
**Config:** 4 tables × 100000 rows | 4 threads | 60s/run | 30s warmup
**Runs:** 5 | **Hypervisor:** Firecracker (verified)
**Storage:** devmapper snapshotter | **Detected:** block-device (virtio-mmio)

> **Note:** VM-exit counts are read from `/sys/kernel/debug/kvm/` global counters.
> Ensure no other KVM workloads run during the benchmark for accurate counts.

---

## Per-Run Results

| Run | TPS | QPS | Min Lat (ms) | Avg Lat (ms) | P99 Lat (ms) | Max Lat (ms) | VM Exits |
|-----|-----|-----|-------------|-------------|-------------|-------------|----------|
| 1 | 642.51 | 12850.15 | 3.24 | 6.22 | 10.84 | 21.58 | 3424905 |
| 2 | 649.60 | 12991.95 | 3.25 | 6.15 | 10.65 | 24.79 | 3343148 |
| 3 | 651.25 | 13024.97 | 3.27 | 6.14 | 10.46 | 28.72 | 3326811 |
| 4 | 640.11 | 12802.21 | 3.26 | 6.24 | 10.65 | 21.46 | 3464900 |
| 5 | 650.68 | 13013.51 | 3.19 | 6.14 | 10.46 | 21.07 | 3368781 |

---

## Aggregate Statistics (across 5 runs)

| Metric             |         Mean |     StdDev |       CV |          Min |          Max |
|--------------------|-------------|-----------|---------|-------------|-------------|
| TPS                |       646.83 |       4.60 |      0.7% |       640.11 |       651.25 |
| QPS                |     12936.56 |      92.00 |      0.7% |     12802.21 |     13024.97 |
| Min Latency (ms)   |         3.24 |       0.03 |      0.9% |         3.19 |         3.27 |
| Avg Latency (ms)   |         6.18 |       0.04 |      0.7% |         6.14 |         6.24 |
| P99 Latency (ms)   |        10.61 |       0.14 |      1.3% |        10.46 |        10.84 |
| Max Latency (ms)   |        23.52 |       2.92 |     12.4% |        21.07 |        28.72 |

### Tail Latency Observations

- **Worst P99 across all runs:** 10.84 ms
- **Worst Max latency across all runs:** 28.72 ms
- **P99 variability (CV):** 1.3% — excellent consistency

---

## VM-Exit Analysis

| Exit Type          |         Mean |     StdDev |       CV |          Min |          Max |
|--------------------|-------------|-----------|---------|-------------|-------------|
| Total Exits        |   3385709.00 |   51719.46 |      1.5% |   3326811.00 |   3464900.00 |
| I/O Exits          |         0.00 |       0.00 |      0.0% |         0.00 |         0.00 |
| MMIO Exits         |    332952.80 |    2358.31 |      0.7% |    329024.00 |    335730.00 |
| IRQ Exits          |    753023.00 |   10422.45 |      1.4% |    740708.00 |    766209.00 |
| Halt Exits         |    473266.00 |    7106.75 |      1.5% |    463320.00 |    483928.00 |

### VM-Exit Breakdown (per-run)

| Run | Total | I/O | MMIO | IRQ | Halt |
|-----|-------|-----|------|-----|------|
| 1 | 3424905 | 0 | 335730 | 763080 | 476136 |
| 2 | 3343148 | 0 | 329024 | 740708 | 475027 |
| 3 | 3326811 | 0 | 331898 | 742232 | 463320 |
| 4 | 3464900 | 0 | 334802 | 766209 | 483928 |
| 5 | 3368781 | 0 | 333310 | 752886 | 467919 |

---

## Exits-per-Transaction

| Run | Exits/TPS |
|-----|-----------|
| 1 | 88.84 |
| 2 | 85.77 |
| 3 | 85.14 |
| 4 | 90.22 |
| 5 | 86.29 |

---

## VM-Exit Root Cause Analysis

> Exit reasons captured via `perf kvm stat` — shows Intel VMX exit reason codes,
> sample counts, and time spent handling each exit type.

### Run 1

```
                                 VM-EXIT    Samples  Samples%     Time%    Min Time    Max Time         Avg time 

                                     msr    1473479    43.96%    10.37%      2.39us   2246.83us      5.17us ( +-   0.07% )
                               interrupt     753893    22.49%     9.16%      2.08us   2450.24us      8.94us ( +-   0.15% )
                                     npf     514902    15.36%    11.10%      2.68us    747.75us     15.84us ( +-   0.09% )
                                     hlt     462814    13.81%    68.75%      1.42us   4855.38us    109.19us ( +-   0.21% )
                                   vintr     140585     4.19%     0.59%      2.00us     93.15us      3.07us ( +-   0.12% )
                               hypercall       5929     0.18%     0.02%      1.71us     75.03us      2.32us ( +-   0.97% )
                                   pause         23     0.00%     0.01%      2.14us   2528.98us    297.54us ( +-  40.96% )

Total Samples:3351625, Total events handled time:73501875.07us.

```

### Run 2

```
                                 VM-EXIT    Samples  Samples%     Time%    Min Time    Max Time         Avg time 

                                     msr    1439337    43.83%     9.98%      2.38us   3110.01us      5.14us ( +-   0.08% )
                               interrupt     734328    22.36%     8.79%      2.07us   3349.94us      8.88us ( +-   0.18% )
                                     npf     507701    15.46%    10.84%      2.58us    384.80us     15.83us ( +-   0.09% )
                                     hlt     463572    14.12%    69.81%      1.43us   4035.07us    111.62us ( +-   0.21% )
                                   vintr     132988     4.05%     0.55%      2.02us    151.61us      3.05us ( +-   0.12% )
                               hypercall       5953     0.18%     0.02%      1.69us     58.11us      2.33us ( +-   0.92% )
                                   pause         21     0.00%     0.00%      2.10us   1428.74us    148.68us ( +-  46.29% )

Total Samples:3283900, Total events handled time:74120859.64us.

```

### Run 3

```
                                 VM-EXIT    Samples  Samples%     Time%    Min Time    Max Time         Avg time 

                                     msr    1432781    43.76%    10.13%      2.35us   3637.86us      5.18us ( +-   0.11% )
                               interrupt     736036    22.48%     8.85%      2.11us   3004.25us      8.81us ( +-   0.16% )
                                     npf     512471    15.65%    11.03%      3.74us    238.01us     15.77us ( +-   0.08% )
                                     hlt     453299    13.84%    69.41%      1.41us   7913.24us    112.23us ( +-   0.22% )
                                   vintr     133869     4.09%     0.56%      2.02us    107.64us      3.06us ( +-   0.11% )
                               hypercall       5953     0.18%     0.02%      1.68us     49.09us      2.32us ( +-   1.00% )
                                   pause         19     0.00%     0.00%      1.71us    277.93us     65.98us ( +-  26.73% )

Total Samples:3274428, Total events handled time:73289269.93us.

```

### Run 4

```
                                 VM-EXIT    Samples  Samples%     Time%    Min Time    Max Time         Avg time 

                                     msr    1516553    44.42%    10.55%      2.39us   2328.58us      5.17us ( +-   0.08% )
                               interrupt     759444    22.24%     9.07%      1.99us   2213.00us      8.88us ( +-   0.15% )
                                     npf     516243    15.12%    10.99%      3.76us    234.31us     15.83us ( +-   0.08% )
                                     hlt     474628    13.90%    68.79%      1.42us   7192.02us    107.84us ( +-   0.22% )
                                   vintr     141363     4.14%     0.58%      2.01us    966.45us      3.06us ( +-   0.25% )
                               hypercall       5954     0.17%     0.02%      1.69us     39.78us      2.27us ( +-   0.55% )
                                   pause         35     0.00%     0.01%      2.23us   2756.71us    155.38us ( +-  51.14% )
                                   cpuid          4     0.00%     0.00%      2.09us      2.60us      2.41us ( +-   4.63% )

Total Samples:3414224, Total events handled time:74402761.52us.

```

### Run 5

```
                                 VM-EXIT    Samples  Samples%     Time%    Min Time    Max Time         Avg time 

                                     msr    1453169    43.96%    10.24%      2.39us   2605.56us      5.19us ( +-   0.06% )
                               interrupt     744966    22.54%     9.00%      2.12us   3258.64us      8.89us ( +-   0.16% )
                                     npf     513593    15.54%    10.93%      3.83us    469.58us     15.67us ( +-   0.08% )
                                     hlt     455594    13.78%    69.25%      1.42us   4035.48us    111.87us ( +-   0.22% )
                                   vintr     132167     4.00%     0.55%      2.07us     81.04us      3.05us ( +-   0.11% )
                               hypercall       5954     0.18%     0.02%      1.69us     39.85us      2.26us ( +-   0.49% )
                                   pause         13     0.00%     0.00%      4.93us    468.54us    138.22us ( +-  32.04% )

Total Samples:3305456, Total events handled time:73596275.55us.

```

### Aggregated Top Exit Reasons

| Exit Reason | Total Samples | Avg Samples/Run | Avg Time (us) |
|-------------|--------------|-----------------|---------------|
| msr                       |      7315319 |         1463064 |          5.17 |
| interrupt                 |      3728667 |          745733 |          8.88 |
| npf                       |      2564910 |          512982 |         15.79 |
| hlt                       |      2309907 |          461981 |        110.55 |
| vintr                     |       680972 |          136194 |          3.06 |
| hypercall                 |        29743 |            5949 |          2.30 |
| pause                     |          111 |              22 |        161.16 |
| cpuid                     |            4 |               4 |          2.41 |

_Raw sysbench output and perf VM-exit reports for each run are saved in `./bench_20260501_133213/`._
