# Docker TPS Variance — Root Cause Analysis

## Verdict: **Your disk is the bottleneck, not Docker.**

The system monitor data makes this unambiguous. Here's the evidence:

---

## Smoking Gun: Run 4 (worst run — 299 TPS)

Run 4 shows the clearest correlation. Two distinct phases:

### Phase 1: High TPS (00:19:03 – 00:19:23) → ~670 TPS
| Time | Disk %util | Disk await | Disk w/s | iowait% | Dirty Pages | TPS |
|------|-----------|-----------|---------|---------|-------------|-----|
| 19:03 | **61%** | 2928ms | 6220 | 3.9% | 1222 | ~670 |
| 19:06 | **68%** | 2823ms | 5027 | 4.5% | 2243 | ~670 |
| 19:13 | **68%** | 2845ms | 5142 | 3.9% | 2533 | ~670 |

### Phase 2: TPS collapse (00:19:26 – 00:19:59) → 64-171 TPS
| Time | Disk %util | Disk await | Disk w/s | iowait% | Dirty Pages | TPS |
|------|-----------|-----------|---------|---------|-------------|-----|
| 19:26 | **92%** | 378ms | 867 | **10.6%** | 2042 | ~171 |
| 19:33 | **91%** | 467ms | 804 | **11.2%** | 1816 | ~139 |
| 19:46 | **95%** | 191ms | 446 | **11.7%** | 1606 | ~82 |
| 19:56 | **95%** | 289ms | 701 | **14.3%** | 1185 | ~65 |
| 19:59 | **93%** | 239ms | 550 | **22.2%** | 1198 | ~65 |

> [!IMPORTANT]
> The state change is clear: disk %util jumps from 65-70% → **92-95%**, iowait spikes from 4% → **22%**, and disk w/s drops from 5000 → **446-868**. This is classic **I/O queue saturation** — the disk is fully occupied and write throughput collapses.

---

## What's Actually Happening

### The pattern across ALL runs

| Run | Avg Disk %util | Max Disk %util | Max iowait% | TPS | Pattern |
|-----|---------------|---------------|-------------|-----|---------|
| 1 | 77.3% | 84.4% | 13.3% | 418 | Moderate stalls |
| 2 | 75.4% | 83.2% | 8.2% | 472 | Moderate stalls |
| 3 | 74.9% | 84.5% | 12.7% | 497 | Moderate stalls |
| 4 | **82.5%** | **95.2%** | **22.2%** | **299** | **Full saturation** |
| 5 | 74.6% | 83.5% | 10.1% | 472 | Moderate stalls |

### Key observations

1. **Disk await times are 1000-2900ms** — your disk is extremely slow. Even in the "fast" phases, each I/O takes 1-3 **seconds** to complete. This is HDD-level latency, not SSD.

2. **Two I/O regimes** visible in the data:
   - **High w/s, lower %util (65-70%)**: Burst writes completing — TPS is good (~670)
   - **Low w/s, high %util (90-95%)**: Disk queue saturated — TPS collapses (<100)

3. **InnoDB dirty pages decrease during stalls** (2533 → 1185 in Run 4) — InnoDB IS flushing, but the disk can't keep up. It's writing out dirty pages as fast as the disk allows, which starves the sysbench transactions of I/O bandwidth.

4. **Memory and CPU are NOT the bottleneck** — ~10GB available throughout, CPU frequency is stable around 2.4-2.9 GHz. CPU frequency does dip to 1.8 GHz occasionally but this correlates with iowait (CPU is sleeping waiting on I/O, not throttling).

---

## Why Kata+FC (devmapper) Doesn't Have This Problem

Kata+FC with devmapper showed **621 TPS, 1.4% CV** — rock solid. Why?

Devmapper uses a **thin-provisioned block device** backed by a pre-allocated sparse file (`/var/lib/containerd/devmapper/data`, 50GB). The I/O path is:

```
InnoDB → virtio-mmio → devmapper thin pool → loopback device → pre-allocated sparse file
```

The key difference: devmapper's thin pool does **copy-on-write at the block level**, which coalesces small random writes into larger sequential writes. The loopback device also acts as a buffer layer. Combined with Firecracker's virtio-mmio block device, the I/O pattern hitting the physical disk is much smoother.

Docker's volume path is:
```
InnoDB → ext4 (host) → physical disk
```

No write coalescing, no intermediate buffering. Every `fsync()` from InnoDB hits the physical disk directly via O_DIRECT. When the disk's I/O queue fills up, everything stalls.

---

## Recommendations

### Option 1: Use tmpfs (eliminates disk entirely)
```bash
docker run -d --tmpfs /var/lib/mysql:size=3g ...
```
This puts MySQL data in RAM. Eliminates ALL disk I/O variance. Best for measuring pure compute/memory overhead of Docker vs Kata. But changes the benchmark semantics (not durable).

### Option 2: Use an SSD
If your Docker volume is on an HDD (the 1-3s await times strongly suggest this), moving to an SSD would drop await to <1ms and eliminate the stalls.

### Option 3: Relax InnoDB durability (match intent, not guarantee)
```
--innodb-flush-log-at-trx-commit=2  # flush to OS, not disk, per commit
--innodb-doublewrite=0               # skip doublewrite buffer
```
This reduces fsync frequency dramatically. But it changes durability semantics.

### Option 4: Accept the variance as a valid result
The variance itself IS the finding: **Docker on HDD has massive I/O variability because there's no intermediate buffer between InnoDB and the physical disk.** Kata+FC's devmapper provides that buffer implicitly. This is a legitimate performance characteristic to report.
