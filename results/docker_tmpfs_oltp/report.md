# MySQL OLTP Benchmark — Docker + tmpfs (Baseline)

**Date:** 2026-05-01 18:51:20
**Kernel:** 6.17.0-22-generic | **Host CPUs:** 16
**Container Resources:** 4 CPUs | 4096 MiB RAM | Pinned to cores 0-3
**Workload:** sysbench oltp\_read\_write
**Config:** 4 tables × 100000 rows | 4 threads | 60s/run | 30s warmup
**Runs:** 5 | **Runtime:** runc (native)
**Storage:** tmpfs (RAM-backed — zero disk I/O) | **Isolation:** None (shared host kernel)
**InnoDB Tuning:** buffer\_pool=1G | io\_capacity=10000/20000 | data on tmpfs

> **Note:** This is the Docker baseline — no hypervisor, no VM exits, no microVM overhead.
> Compare directly with Kata+Firecracker results using identical workload parameters.

---

## Per-Run Results

| Run | TPS | QPS | Min Lat (ms) | Avg Lat (ms) | P99 Lat (ms) | Max Lat (ms) |
|-----|-----|-----|-------------|-------------|-------------|-------------|
| 1 | 835.29 | 16705.88 | 2.78 | 4.78 | 10.09 | 24.63 |
| 2 | 837.48 | 16749.59 | 2.77 | 4.77 | 10.09 | 24.79 |
| 3 | 818.03 | 16360.63 | 2.76 | 4.88 | 10.46 | 20.66 |
| 4 | 877.02 | 17540.47 | 2.95 | 4.55 | 8.43 | 20.51 |
| 5 | 849.73 | 16994.56 | 2.82 | 4.70 | 9.73 | 22.18 |

---

## Aggregate Statistics (across 5 runs)

| Metric             |         Mean |     StdDev |       CV |          Min |          Max |
|--------------------|-------------|-----------|---------|-------------|-------------|
| TPS                |       843.51 |      19.57 |      2.3% |       818.03 |       877.02 |
| QPS                |     16870.23 |     391.39 |      2.3% |     16360.63 |     17540.47 |
| Min Latency (ms)   |         2.82 |       0.07 |      2.5% |         2.76 |         2.95 |
| Avg Latency (ms)   |         4.74 |       0.11 |      2.3% |         4.55 |         4.88 |
| P99 Latency (ms)   |         9.76 |       0.70 |      7.2% |         8.43 |        10.46 |
| Max Latency (ms)   |        22.55 |       1.86 |      8.2% |        20.51 |        24.79 |

### Tail Latency Observations

- **Worst P99 across all runs:** 10.46 ms
- **Worst Max latency across all runs:** 24.79 ms
- **P99 variability (CV):** 7.2% — acceptable variability

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
18:45:59   0.80           94.00          97.00     0.0         2024         0               8453          2864
18:46:02   0.10           0.00           1.00      0.0         2065         0               8453          2486
18:46:06   0.00           0.00           0.00      0.0         1984         0               8452          2601
18:46:09   0.00           1.00           1.00      0.0         1773         0               8451          2894
18:46:12   0.00           0.00           0.00      0.0         1945         0               8464          2648
18:46:16   0.00           0.00           0.00      0.0         1955         0               8456          2629
18:46:19   0.00           0.00           0.00      0.0         1868         0               8420          2894
18:46:22   0.20           21.00          5.00      0.0         1956         0               8294          2894
18:46:26   0.00           0.00           0.00      0.0         2093         0               8409          2346
18:46:29   1.60           106.00         177.00    0.0         1858         0               8391          2589
18:46:32   0.00           0.00           0.00      0.0         1960         0               8399          2753
18:46:36   0.00           0.00           0.00      0.0         2228         0               8403          2894
18:46:39   0.00           16.00          62.00     0.0         1760         0               8392          2892
18:46:42   0.20           10.00          3.00      0.0         2008         0               8380          2667
18:46:46   1.50           113.00         171.00    0.0         2184         0               8287          2600
18:46:49   0.00           0.00           0.00      0.0         1831         0               8204          2894
18:46:52   1.70           0.00           0.00      0.0         2028         0               8332          2764
18:46:56   0.00           0.00           0.00      0.0         2146         0               8341          2694
```

**Summary:**
- Disk %util: avg=0.3%, max=1.7%
- Disk await: avg=20.1ms, max=113.0ms
- CPU iowait: avg=0.0%, max=0.0%
- InnoDB dirty pages: avg=1981, max=2228
- Pending fsyncs: avg=0, max=0

### Run 2 — System Monitor

```
timestamp  disk_util_pct  disk_await_ms  disk_wps  iowait_pct  dirty_pages  pending_fsyncs  mem_avail_mb  cpu_mhz
18:47:04   0.00           21.00          3.00      0.0         1275         0               8380          2433
18:47:08   0.00           0.00           8.00      0.0         2249         0               8381          2836
18:47:11   0.00           0.00           0.00      0.0         1470         0               8379          2889
18:47:14   0.00           0.00           0.00      0.0         1949         0               8374          2696
18:47:18   0.00           0.00           1.00      0.0         2067         0               8366          2650
18:47:21   0.20           11.00          8.00      0.0         1414         0               8362          2763
18:47:24   0.00           0.00           0.00      0.0         1911         0               8349          2826
18:47:28   0.00           0.00           0.00      0.0         1913         0               8336          2693
18:47:31   0.10           4.00           43.00     0.0         1672         0               8372          2832
18:47:34   0.00           0.00           0.00      0.0         1993         0               8375          2631
18:47:38   0.00           0.00           0.00      0.0         2149         0               8375          2620
18:47:41   1.10           95.00          88.00     0.6         1780         0               8242          2894
18:47:44   0.20           53.00          7.00      0.0         2017         0               8107          2894
18:47:48   0.30           15.00          13.00     0.0         2140         0               8255          2828
18:47:51   0.00           0.00           0.00      0.0         1780         0               8260          2669
18:47:54   0.00           0.00           0.00      0.0         2005         0               8251          2894
18:47:58   0.00           0.00           0.00      0.0         2179         0               8282          2654
18:48:01   0.10           1.00           16.00     0.0         1620         0               8291          2693
```

**Summary:**
- Disk %util: avg=0.1%, max=1.1%
- Disk await: avg=11.1ms, max=95.0ms
- CPU iowait: avg=0.0%, max=0.6%
- InnoDB dirty pages: avg=1866, max=2249
- Pending fsyncs: avg=0, max=0

### Run 3 — System Monitor

```
timestamp  disk_util_pct  disk_await_ms  disk_wps  iowait_pct  dirty_pages  pending_fsyncs  mem_avail_mb  cpu_mhz
18:48:09   0.20           0.00           36.00     0.0         1349         0               8299          2622
18:48:13   0.00           0.00           0.00      0.0         2422         0               8299          2807
18:48:16   0.30           24.00          30.00     0.0         1620         0               8275          2870
18:48:19   0.20           28.00          25.00     0.0         2109         0               8105          2895
18:48:23   0.10           15.00          9.00      0.0         2095         0               8099          2682
18:48:26   0.00           0.00           0.00      0.0         2016         0               8100          2763
18:48:30   0.00           0.00           1.00      0.0         2113         0               8250          2788
18:48:33   0.00           0.00           0.00      0.0         2147         0               8233          2693
18:48:36   0.00           0.00           0.00      0.0         1978         0               8240          2469
18:48:40   0.00           0.00           0.00      0.0         2005         0               8230          2894
18:48:43   0.00           0.00           0.00      0.0         2134         0               8220          2789
18:48:46   0.00           0.00           0.00      0.0         2007         0               8226          2894
18:48:50   1.10           61.00          96.00     0.0         2126         0               8075          2651
18:48:53   1.20           98.00          115.00    0.0         2123         0               8011          2754
18:48:56   0.00           0.00           0.00      0.0         2008         0               8002          2454
18:49:00   0.00           0.00           0.00      0.0         2065         0               8170          2894
18:49:03   0.00           0.00           0.00      0.0         2201         0               8168          2688
18:49:06   0.00           0.00           0.00      0.0         1903         0               8180          2690
```

**Summary:**
- Disk %util: avg=0.2%, max=1.2%
- Disk await: avg=12.6ms, max=98.0ms
- CPU iowait: avg=0.0%, max=0.0%
- InnoDB dirty pages: avg=2023, max=2422
- Pending fsyncs: avg=0, max=0

### Run 4 — System Monitor

```
timestamp  disk_util_pct  disk_await_ms  disk_wps  iowait_pct  dirty_pages  pending_fsyncs  mem_avail_mb  cpu_mhz
18:49:15   0.00           0.00           10.00     0.0         1437         0               8173          2771
18:49:18   0.00           3.00           27.00     0.0         1928         0               8188          2686
18:49:21   0.10           21.00          2.00      0.0         1954         0               8184          2623
18:49:25   0.80           57.00          53.00     0.0         2098         0               8181          2446
18:49:28   0.00           0.00           0.00      0.0         1896         0               8185          2828
18:49:31   1.40           99.00          177.00    0.0         1998         0               7953          2776
18:49:35   2.20           219.00         262.00    0.0         2141         0               7985          2893
18:49:38   0.00           1.00           5.00      0.0         1497         0               8116          2757
18:49:41   0.00           0.00           0.00      0.0         1992         0               8128          2448
18:49:45   0.00           0.00           0.00      0.0         2124         0               8148          2580
18:49:48   0.10           13.00          23.00     0.0         1631         0               8152          2435
18:49:51   0.00           0.00           0.00      0.0         2031         0               8142          2398
18:49:55   0.80           79.00          61.00     0.0         2118         0               8140          2581
18:49:58   0.10           16.00          14.00     0.0         1528         0               8123          2563
18:50:01   0.00           0.00           0.00      0.0         1970         0               8131          2894
18:50:05   0.20           10.00          4.00      0.0         2114         0               8119          2607
18:50:08   0.00           0.00           0.00      0.0         1619         0               8122          2596
18:50:11   0.00           0.00           0.00      0.0         2058         0               8118          2893
```

**Summary:**
- Disk %util: avg=0.3%, max=2.2%
- Disk await: avg=28.8ms, max=219.0ms
- CPU iowait: avg=0.0%, max=0.0%
- InnoDB dirty pages: avg=1896, max=2141
- Pending fsyncs: avg=0, max=0

### Run 5 — System Monitor

```
timestamp  disk_util_pct  disk_await_ms  disk_wps  iowait_pct  dirty_pages  pending_fsyncs  mem_avail_mb  cpu_mhz
18:50:20   0.00           0.00           0.00      0.0         1540         0               8118          2486
18:50:23   0.10           0.00           1.00      0.0         2146         0               8151          2835
18:50:26   0.20           10.00          12.00     0.0         1920         0               8165          2894
18:50:30   0.10           0.00           1.00      0.0         2117         0               8154          2318
18:50:33   0.10           16.00          47.00     0.0         1911         0               8155          2395
18:50:36   0.00           0.00           0.00      0.0         1951         0               8145          2789
18:50:40   0.00           1.00           2.00      0.0         2135         0               8132          2752
18:50:43   0.00           0.00           0.00      0.0         1856         0               8132          2839
18:50:46   0.10           10.00          3.00      0.0         2069         0               8120          2825
18:50:50   0.10           3.00           32.00     0.0         2193         0               7902          2894
18:50:53   2.10           191.00         251.00    0.6         1949         0               7861          2894
18:50:56   0.00           0.00           0.00      0.0         2052         0               7992          2782
18:51:00   0.00           0.00           0.00      0.0         2146         0               8011          2852
18:51:03   0.10           12.00          3.00      0.0         1813         0               8019          2787
18:51:06   0.00           16.00          64.00     0.0         2049         0               8027          2894
18:51:10   0.00           0.00           0.00      0.0         2176         0               8017          2810
18:51:13   0.10           19.00          2.00      0.0         1825         0               8017          2682
18:51:16   0.00           0.00           0.00      0.0         2043         0               7853          2892
```

**Summary:**
- Disk %util: avg=0.2%, max=2.1%
- Disk await: avg=15.4ms, max=191.0ms
- CPU iowait: avg=0.0%, max=0.6%
- InnoDB dirty pages: avg=1994, max=2193
- Pending fsyncs: avg=0, max=0

---

## Comparison Notes

This Docker baseline measures MySQL OLTP performance **without any hypervisor overhead**.
When comparing with Kata+Firecracker results:

- **TPS/QPS delta** = overhead introduced by the microVM + virtio-mmio block I/O
- **Latency delta** = additional latency from VM exits (MSR, interrupt, NPF, HLT)
- **No VM-exit section** — Docker containers share the host kernel directly
- **Storage** — Docker uses overlay2 + volume (host filesystem), Kata+FC uses devmapper (block device)

