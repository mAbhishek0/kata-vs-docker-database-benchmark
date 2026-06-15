# Isolation Test Script — Variance Root Cause Investigation

## Goal

Create `benchmark_isolation_test.sh` based on [benchmark_oltp_docker_tmpfs.sh](file:///home/ab/Downloads/kata_fc_install_guide/benchmark_oltp_docker_tmpfs.sh) that sequentially tests hypotheses for Docker TPS variance. Each hypothesis: apply fix → benchmark 3 runs → revert. High-resolution per-core diagnostics run throughout.

## Script Structure

```
Phase 0: Preflight + snapshot system state
Phase 1: Image + container launch (same tmpfs setup, reused across all phases)
Phase 2: Sysbench prepare + warmup

Phase 3: BASELINE (no fixes) — 3 runs
Phase 4: H1 - Disable THP + NUMA balancing — apply → 3 runs → revert
Phase 5: H2 - CPU isolation via systemd slices — apply → 3 runs → revert  
Phase 6: H3 - Combined (THP off + systemd CPU isolation) — apply → 3 runs → revert

Phase 7: Cleanup container
Phase 8: Generate unified comparison report
```

> [!IMPORTANT]
> The container stays alive across all phases — only the host tuning changes. This ensures MySQL buffer pool state is identical, eliminating warmup differences as a confound.

---

## Proposed Changes

### [NEW] [benchmark_isolation_test.sh](file:///home/ab/Downloads/kata_fc_install_guide/benchmark_isolation_test.sh)

#### Configuration (inherited from tmpfs script)
- 3 runs per phase (not 5) — 4 phases × 3 runs = 12 total runs, ~15 min
- Same: 4 tables × 100K rows, 4 threads, 60s/run, 30s warmup, cores 0-3, 4GB RAM, tmpfs
- Container reused across phases (no restart between hypotheses)

#### High-Resolution Monitor (replaces existing monitor)

Runs every **1 second** (not 2s) and captures per-core data:

| Metric | Source | Why |
|--------|--------|-----|
| Per-core usr/sys/irq/softirq/idle % | `mpstat -P 0-3 1 1` | See if host tasks steal CPU from MySQL |
| Context switches on cores 0-3 | `/proc/stat` (ctxt field) | High ctxt = scheduler thrashing |
| Runqueue depth on cores 0-3 | `/proc/schedstat` | >1 means contention |
| THP compaction stalls | `/proc/vmstat` (compact_stall) | Spikes = THP jitter |
| IRQ counts on cores 0-3 | `/proc/interrupts` diff | Interrupt storms |
| InnoDB dirty pages | MySQL query | Same as before |
| Available memory | `/proc/meminfo` | Track pressure |

Output: `{results_dir}/phase_{N}_run_{R}_hires_monitor.csv`

#### Phase 3: BASELINE (no changes)
- Captures the "Docker tmpfs as-is" behavior for this run
- 3 runs with high-res monitor

#### Phase 4: H1 — Disable THP + NUMA Balancing
Hypothesis: THP compaction and NUMA rebalancing cause multi-ms stalls.

**Apply:**
```bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
echo 0 > /proc/sys/kernel/numa_balancing
```

**Revert:**
```bash
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
echo madvise > /sys/kernel/mm/transparent_hugepage/defrag
echo 1 > /proc/sys/kernel/numa_balancing
```

> [!NOTE]
> This is the least disruptive fix — runtime sysctl changes, no reboot, no process migration. Testing it first because it's easy to validate.

#### Phase 5: H2 — CPU Isolation via systemd Slices
Hypothesis: Host daemons contend on cores 0-3.

**Apply:**
```bash
sudo systemctl set-property system.slice AllowedCPUs=4-15
sudo systemctl set-property user.slice AllowedCPUs=4-15
# Also move IRQs off cores 0-3
for irqdir in /proc/irq/*/; do
    echo "fff0" > "${irqdir}smp_affinity" 2>/dev/null || true  # cores 4-15
done
```

**Revert:**
```bash
sudo systemctl set-property system.slice AllowedCPUs=0-15
sudo systemctl set-property user.slice AllowedCPUs=0-15
for irqdir in /proc/irq/*/; do
    echo "ffff" > "${irqdir}smp_affinity" 2>/dev/null || true  # all cores
done
```

> [!WARNING]
> `systemctl set-property` is persistent by default. The script must use `--runtime` flag so changes don't survive reboot, or explicitly revert.

#### Phase 6: H3 — Combined (THP off + CPU isolation)
Applies both Phase 4 and Phase 5 fixes simultaneously. Reverts both after.

This is the "maximum isolation without kernel boot params" configuration. If this matches Kata+FC's CV, we've proven the thesis.

#### Phase 8: Unified Report

Single `report.md` with:

1. **Per-phase per-run table** (TPS, QPS, P99, Max Lat)
2. **Phase comparison summary:**

```
| Phase | Config | Mean TPS | CV | Mean P99 | Notes |
|-------|--------|---------|-----|----------|-------|
| Baseline | tmpfs, no fixes | ? | ? | ? | |
| H1 | +THP off +NUMA off | ? | ? | ? | |
| H2 | +CPU isolation +IRQ affinity | ? | ? | ? | |
| H3 | Combined (H1+H2) | ? | ? | ? | |
| Kata+FC (ref) | devmapper, microVM | 646.83 | 0.7% | 10.61 | from previous bench |
```

3. **High-res monitor summaries** per phase (avg/max context switches, compaction stalls, IRQ counts on cores 0-3)
4. **Conclusion**: Which hypothesis contributed most to variance reduction

---

## Open Questions

> [!IMPORTANT]
> **Q1**: Should I save the original THP/NUMA values at script start and restore those exact values, or assume the defaults (`madvise`/`1`)? Your system may have custom settings.

> [!IMPORTANT]
> **Q2**: The `systemctl set-property` command is persistent across reboots by default. Should I use the `--runtime` flag (transient, lost on reboot) to be safe? I'm leaning yes.

> [!IMPORTANT]
> **Q3**: 3 runs per phase gives 12 total runs (~15 min). Would you prefer 5 runs for stronger statistics? That would be ~25 min total.

---

## Verification Plan

### Automated
- Script prints phase transition logs with clear `=== PHASE N: ... ===` markers
- Each apply/revert step logs the before/after state (e.g., reads back THP setting after changing it)
- Final report includes Kata+FC reference numbers for inline comparison

### Manual
- Run the script: `sudo bash benchmark_isolation_test.sh`
- Review `report.md` for CV progression across phases
- Check that all reverts succeeded (system returns to baseline state)
