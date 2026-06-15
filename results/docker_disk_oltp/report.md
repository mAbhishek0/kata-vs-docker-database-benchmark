# MySQL OLTP Benchmark — Docker (Baseline)

**Date:** 2026-05-01 18:58:51
**Kernel:** 6.17.0-22-generic | **Host CPUs:** 16
**Container Resources:** 4 CPUs | 4096 MiB RAM | Pinned to cores 0-3
**Workload:** sysbench oltp\_read\_write
**Config:** 4 tables × 100000 rows | 4 threads | 60s/run | 30s warmup
**Runs:** 5 | **Runtime:** runc (native)
**Storage:** overlay2 + Docker volume (bypasses overlay2 for data) | **Isolation:** None (shared host kernel)
**InnoDB Tuning:** buffer\_pool=2G | flush\_method=O\_DIRECT | io\_capacity=2000/4000

> **Note:** This is the Docker baseline — no hypervisor, no VM exits, no microVM overhead.
> Compare directly with Kata+Firecracker results using identical workload parameters.

---

## Per-Run Results

| Run | TPS | QPS | Min Lat (ms) | Avg Lat (ms) | P99 Lat (ms) | Max Lat (ms) |
|-----|-----|-----|-------------|-------------|-------------|-------------|
| 1 | 474.08 | 9481.67 | 4.13 | 8.43 | 25.74 | 211.26 |
| 2 | 281.60 | 5632.02 | 4.12 | 14.19 | 108.68 | 380.42 |
| 3 | 475.43 | 9508.53 | 4.07 | 8.41 | 24.83 | 146.89 |
| 4 | 535.52 | 10710.35 | 4.04 | 7.46 | 24.38 | 91.90 |
| 5 | 479.84 | 9596.82 | 3.92 | 8.33 | 24.83 | 91.52 |

---

## Aggregate Statistics (across 5 runs)

| Metric             |         Mean |     StdDev |       CV |          Min |          Max |
|--------------------|-------------|-----------|---------|-------------|-------------|
| TPS                |       449.29 |      86.93 |     19.3% |       281.60 |       535.52 |
| QPS                |      8985.88 |    1738.64 |     19.3% |      5632.02 |     10710.35 |
| Min Latency (ms)   |         4.06 |       0.08 |      1.9% |         3.92 |         4.13 |
| Avg Latency (ms)   |         9.36 |       2.44 |     26.1% |         7.46 |        14.19 |
| P99 Latency (ms)   |        41.69 |      33.50 |     80.3% |        24.38 |       108.68 |
| Max Latency (ms)   |       184.40 |     107.46 |     58.3% |        91.52 |       380.42 |

### Tail Latency Observations

- **Worst P99 across all runs:** 108.68 ms
- **Worst Max latency across all runs:** 380.42 ms
- **P99 variability (CV):** 80.3% — HIGH variability — investigate

---

## Comparison Notes

This Docker baseline measures MySQL OLTP performance **without any hypervisor overhead**.
When comparing with Kata+Firecracker results:

- **TPS/QPS delta** = overhead introduced by the microVM + virtio-mmio block I/O
- **Latency delta** = additional latency from VM exits (MSR, interrupt, NPF, HLT)
- **No VM-exit section** — Docker containers share the host kernel directly
- **Storage** — Docker uses overlay2 (host filesystem), Kata+FC uses devmapper (block device)

---

## System Diagnostics (per-run)

> Background monitor captured disk I/O, CPU iowait, InnoDB dirty pages,
> pending fsyncs, available memory, and CPU frequency every ~2s during each run.
> Correlate timestamps with the sysbench `--report-interval` output above.

### Run 1 — System Monitor

```
timestamp  disk_util_pct  disk_await_ms  disk_wps  iowait_pct  dirty_pages  pending_fsyncs  mem_avail_mb  cpu_mhz
18:53:30   58.30          2273.00        4563.00   3.8         2208         1               8838          2894
18:53:33   66.60          2783.00        5087.00   4.5         2317         2               8880          2772
18:53:36   68.70          2763.00        5208.00   4.5         2238         1               8880          2893
18:53:40   67.30          2852.00        5303.00   3.8         2286         0               8804          2843
18:53:43   81.50          1039.00        2097.00   5.0         2291         1               8806          2782
18:53:46   83.40          1072.00        2020.00   10.0        1954         2               8812          1947
18:53:49   82.30          1153.00        2141.00   6.2         1832         0               8809          2031
18:53:53   84.00          1066.00        1896.00   4.5         1891         0               8812          2659
18:53:56   68.70          2882.00        5207.00   5.2         2072         1               8807          2737
18:53:59   70.40          2900.00        5326.00   3.9         2289         0               8804          2894
18:54:03   66.50          2859.00        5187.00   3.8         2414         0               8811          2739
18:54:06   68.60          2848.00        5208.00   3.9         2187         0               8807          2794
18:54:09   80.50          1114.00        2041.00   10.2        2092         1               8815          2224
18:54:13   80.30          1109.00        2044.00   6.3         1909         1               8819          2512
18:54:16   79.60          1193.07        2143.56   6.2         1959         2               8834          2371
18:54:19   82.10          1005.00        1841.00   11.9        1836         0               8836          2530
18:54:23   82.50          1158.00        2070.00   5.7         2003         1               8830          2757
18:54:26   81.70          1212.00        2181.00   5.6         2019         1               8827          2683
```

**Summary:**
- Disk %util: avg=75.2%, max=84.0%
- Disk await: avg=1848.9ms, max=2900.0ms
- CPU iowait: avg=5.8%, max=11.9%
- InnoDB dirty pages: avg=2100, max=2414
- Pending fsyncs: avg=1, max=2

### Run 2 — System Monitor

```
timestamp  disk_util_pct  disk_await_ms  disk_wps  iowait_pct  dirty_pages  pending_fsyncs  mem_avail_mb  cpu_mhz
18:54:35   75.30          1149.00        2353.00   11.3        915          2               8830          2776
18:54:38   84.90          956.00         1753.00   4.4         1483         0               8832          2894
18:54:41   68.10          2819.00        5100.00   4.5         2192         1               8826          2837
18:54:45   68.70          2802.00        5123.00   4.5         2441         0               8814          2687
18:54:48   67.30          2832.00        5195.00   4.5         2478         1               8823          2863
18:54:51   64.50          2945.00        5280.00   3.8         2321         1               8829          2836
18:54:55   72.90          2683.00        4630.00   3.9         2408         0               8820          2894
18:54:58   91.90          355.00         857.00    12.3        2072         2               8818          1870
18:55:01   92.20          438.00         921.00    8.8         1674         2               8819          2365
18:55:05   90.00          494.00         931.00    10.6        1594         1               8816          2669
18:55:08   90.00          449.00         921.00    6.8         1600         0               8812          2321
18:55:11   94.10          372.00         812.00    8.8         1530         2               8815          2194
18:55:14   92.10          465.00         970.00    12.9        1347         1               8822          2135
18:55:18   94.70          401.00         743.00    16.7        1316         2               8826          2420
18:55:21   93.40          291.00         672.00    9.2         1102         1               8825          2541
18:55:24   95.30          283.00         643.00    11.0        1054         2               8826          2130
18:55:28   93.50          307.00         692.00    11.0        980          2               8820          2250
18:55:31   91.10          280.00         635.00    12.3        916          1               8825          2455
```

**Summary:**
- Disk %util: avg=84.4%, max=95.3%
- Disk await: avg=1128.9ms, max=2945.0ms
- CPU iowait: avg=8.7%, max=16.7%
- InnoDB dirty pages: avg=1635, max=2478
- Pending fsyncs: avg=1, max=2

### Run 3 — System Monitor

```
timestamp  disk_util_pct  disk_await_ms  disk_wps  iowait_pct  dirty_pages  pending_fsyncs  mem_avail_mb  cpu_mhz
18:55:40   65.50          2376.00        4439.00   3.9         1467         1               8828          2807
18:55:43   65.20          2894.00        5091.00   4.5         2325         1               8856          2894
18:55:47   69.10          2905.00        5214.00   3.8         2452         1               8865          2721
18:55:50   68.20          2862.00        5216.00   4.5         2587         1               8816          2894
18:55:53   67.90          2904.00        5222.00   7.0         2311         1               8813          2738
18:55:57   70.60          2540.00        4555.00   5.7         2459         0               8816          2788
18:56:00   80.30          1167.00        1957.00   7.5         2246         1               8811          2607
18:56:03   80.40          1182.00        2068.00   5.1         2103         2               8815          2693
18:56:06   79.60          1186.00        2038.00   7.0         2069         0               8819          1995
18:56:10   77.70          1160.00        2001.00   5.6         2184         1               8824          2765
18:56:13   80.70          1242.00        2068.00   6.3         2265         2               8808          1744
18:56:16   81.80          1191.00        2014.00   8.2         2087         1               8807          2450
18:56:20   79.30          1246.00        2112.00   5.7         2165         1               8812          2693
18:56:23   81.60          1175.00        2037.00   5.7         2282         0               8826          2044
18:56:26   82.20          1027.00        1946.00   12.5        2098         1               8829          2831
18:56:30   82.60          994.00         1754.00   5.7         2096         1               8828          2778
18:56:33   70.80          2898.00        5166.00   4.5         2551         1               8820          2794
18:56:36   67.80          2906.00        5212.00   4.5         2376         1               8830          2785
```

**Summary:**
- Disk %util: avg=75.1%, max=82.6%
- Disk await: avg=1880.8ms, max=2906.0ms
- CPU iowait: avg=6.0%, max=12.5%
- InnoDB dirty pages: avg=2229, max=2587
- Pending fsyncs: avg=1, max=2

### Run 4 — System Monitor

```
timestamp  disk_util_pct  disk_await_ms  disk_wps  iowait_pct  dirty_pages  pending_fsyncs  mem_avail_mb  cpu_mhz
18:56:45   62.10          2683.00        5262.00   3.8         1366         1               8832          2843
18:56:48   67.40          2843.00        5028.00   4.5         2249         1               8810          2856
18:56:52   83.80          1147.00        2002.00   5.6         2365         1               8802          2782
18:56:55   68.40          2838.00        5069.00   3.8         2434         1               8798          2818
18:56:58   71.20          2927.00        5233.00   3.8         2509         1               8809          2724
18:57:02   68.80          2959.00        5328.00   4.5         2584         0               8828          2894
18:57:05   66.20          2927.00        5283.00   3.9         2571         2               8824          2534
18:57:08   69.00          2915.00        5251.00   4.5         2403         1               8842          2894
18:57:12   80.70          1067.00        1927.00   6.2         2204         1               8855          2847
18:57:15   85.20          1136.00        1905.00   5.0         2112         0               8849          2696
18:57:18   81.30          1168.00        1994.00   8.3         1896         0               8830          2894
18:57:22   69.20          2893.00        5079.00   4.5         2184         1               8843          2596
18:57:25   65.90          2855.00        5059.00   3.8         2550         1               8844          2693
18:57:28   68.70          2906.00        5174.00   3.9         2375         1               8838          2894
18:57:31   70.50          3032.00        5394.00   3.8         2482         1               8853          2720
18:57:35   66.70          2872.00        5086.00   4.5         2522         1               8841          2828
18:57:38   81.70          1101.00        1935.00   7.5         2257         0               8866          2195
18:57:41   82.30          1115.00        1871.00   8.1         2072         1               8875          2622
```

**Summary:**
- Disk %util: avg=72.7%, max=85.2%
- Disk await: avg=2299.1ms, max=3032.0ms
- CPU iowait: avg=5.0%, max=8.3%
- InnoDB dirty pages: avg=2285, max=2584
- Pending fsyncs: avg=1, max=2

### Run 5 — System Monitor

```
timestamp  disk_util_pct  disk_await_ms  disk_wps  iowait_pct  dirty_pages  pending_fsyncs  mem_avail_mb  cpu_mhz
18:57:50   63.30          2444.00        4235.00   5.8         1113         2               8787          2693
18:57:54   68.10          2883.00        5152.00   4.5         2100         1               8808          2894
18:57:57   70.70          2895.00        5208.00   3.8         2409         1               8806          2693
18:58:00   66.60          2893.00        5198.00   5.7         2326         1               8808          2883
18:58:04   67.20          2902.00        5154.00   3.8         2479         1               8811          2725
18:58:07   67.80          2903.00        5294.00   3.8         2481         1               8800          2755
18:58:10   82.80          1117.00        1987.00   6.3         2255         2               8802          2704
18:58:13   80.60          1142.00        1933.00   8.8         2023         1               8814          2641
18:58:17   80.40          1152.00        1941.00   6.3         2100         1               8818          2351
18:58:20   80.20          1232.00        2084.00   6.3         2206         2               8834          2085
18:58:23   80.50          1234.00        2092.00   9.5         2074         1               8871          2836
18:58:27   78.70          1182.00        2065.00   5.1         2137         1               8873          2720
18:58:30   85.60          905.00         1568.00   6.9         2196         1               8857          2381
18:58:33   82.90          1185.00        2014.00   10.1        2094         1               8813          2693
18:58:37   79.00          1108.00        1894.00   6.2         2141         1               8808          2803
18:58:40   83.10          1190.00        2042.00   5.7         2174         1               8798          2702
18:58:43   68.90          2851.00        5009.00   4.5         2314         1               8811          2894
18:58:46   65.80          2873.00        5012.00   4.5         2517         1               8807          2894
```

**Summary:**
- Disk %util: avg=75.1%, max=85.6%
- Disk await: avg=1893.9ms, max=2903.0ms
- CPU iowait: avg=6.0%, max=10.1%
- InnoDB dirty pages: avg=2174, max=2517
- Pending fsyncs: avg=1, max=2

---

## Comparison Notes

This Docker baseline measures MySQL OLTP performance **without any hypervisor overhead**.
When comparing with Kata+Firecracker results:

- **TPS/QPS delta** = overhead introduced by the microVM + virtio-mmio block I/O
- **Latency delta** = additional latency from VM exits (MSR, interrupt, NPF, HLT)
- **No VM-exit section** — Docker containers share the host kernel directly
- **Storage** — Docker uses overlay2 + volume (host filesystem), Kata+FC uses devmapper (block device)

