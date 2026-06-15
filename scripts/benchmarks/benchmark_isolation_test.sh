#!/usr/bin/env bash
# Isolation Test - Docker TPS Variance Root Cause Investigation
# Sequentially tests hypotheses for Docker OLTP TPS variance.
# Usage: sudo bash benchmark_isolation_test.sh
set -euo pipefail

# --- Configuration (matches Kata+FC and Docker tmpfs scripts) ---
CONTAINER="mysql-bench-isolation"
IMAGE="mysql-bench:local"
MYSQL_PASS="benchpass"
RUNS_PER_PHASE=4
TABLES=4
TABLE_SIZE=100000
THREADS=4
DURATION=60
WARMUP=30
REPORT_INTERVAL=10
RESULTS_DIR="./bench_isolation_$(date +%Y%m%d_%H%M%S)"

# --- Resource Limits ---
VCPUS=4
MEMORY_MB=4096
PIN_CORES="0-3"
TOTAL_CORES="0-15"        # 8C/16T system
NON_BENCH_CORES="4-15"    # cores for host daemons when isolating
IRQ_MASK_ISOLATE="fff0"   # bits 4-15 (move IRQs off 0-3)
IRQ_MASK_ALL="ffff"       # bits 0-15 (all cores)

# --- Kata+FC Reference (hardcoded from previous benchmark) ---
KATA_REF_TPS=646.83
KATA_REF_CV=0.7
KATA_REF_P99=10.61

# --- Saved System State (populated in Phase 0) ---
ORIG_THP_ENABLED=""
ORIG_THP_DEFRAG=""
ORIG_NUMA_BALANCING=""

# --- Helpers ---
log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }
docker_exec() { docker exec "$CONTAINER" "$@"; }

compute_stats() {
    awk -v vals="$1" 'BEGIN {
        n = split(vals, a, " ")
        sum = 0; for (i=1;i<=n;i++) sum += a[i]
        mean = sum / n
        sq = 0; for (i=1;i<=n;i++) sq += (a[i] - mean)^2
        stddev = sqrt(sq / n)
        cv = (mean > 0) ? (stddev / mean * 100) : 0
        mn = a[1]; mx = a[1]
        for (i=2;i<=n;i++) { if (a[i]<mn) mn=a[i]; if (a[i]>mx) mx=a[i] }
        printf "%.2f %.2f %.1f %.2f %.2f\n", mean, stddev, cv, mn, mx
    }'
}

# --- High-resolution monitor ---
# Per-core metrics every 1s on cores 0-3
MONITOR_PID=""

hires_monitor_start() {
    local outfile="$1"
    (
        echo "timestamp,cpu0_usr,cpu0_sys,cpu0_irq,cpu0_soft,cpu0_idle,cpu1_usr,cpu1_sys,cpu1_irq,cpu1_soft,cpu1_idle,cpu2_usr,cpu2_sys,cpu2_irq,cpu2_soft,cpu2_idle,cpu3_usr,cpu3_sys,cpu3_irq,cpu3_soft,cpu3_idle,ctxt_switches,rq0,rq1,rq2,rq3,compact_stall,irq_core0,irq_core1,irq_core2,irq_core3,dirty_pages,mem_avail_mb"

        # Snapshot initial values for deltas
        prev_ctxt=$(awk '/^ctxt/ {print $2}' /proc/stat)
        prev_compact=$(awk '/compact_stall/ {print $2}' /proc/vmstat)

        while true; do
            ts=$(date +%H:%M:%S.%N | cut -c1-12)

            # Per-core CPU usage via mpstat (1s sample)
            mpstat_out=$(mpstat -P 0,1,2,3 1 1 2>/dev/null | tail -4)
            cpu_data=""
            while IFS= read -r line; do
                # fields: usr nice sys iowait irq soft steal guest gnice idle
                vals=$(echo "$line" | awk '{printf "%s,%s,%s,%s,%s", $3,$5,$6,$7,$12}')
                cpu_data="${cpu_data:+$cpu_data,}$vals"
            done <<< "$mpstat_out"

            # Context switches (delta)
            cur_ctxt=$(awk '/^ctxt/ {print $2}' /proc/stat)
            delta_ctxt=$((cur_ctxt - prev_ctxt))
            prev_ctxt=$cur_ctxt

            # Runqueue depth per core from /proc/schedstat
            # Format per CPU line: cpu<N> <...> field 2 = time running, field 3 = time waiting
            # We use nr_running from /proc/sched_debug if available, else approximate
            rq0=0; rq1=0; rq2=0; rq3=0
            if [[ -f /proc/schedstat ]]; then
                rq0=$(awk '/^cpu0/ {print NF >= 9 ? $8 : 0}' /proc/schedstat)
                rq1=$(awk '/^cpu1/ {print NF >= 9 ? $8 : 0}' /proc/schedstat)
                rq2=$(awk '/^cpu2/ {print NF >= 9 ? $8 : 0}' /proc/schedstat)
                rq3=$(awk '/^cpu3/ {print NF >= 9 ? $8 : 0}' /proc/schedstat)
            fi

            # THP compaction stalls (delta)
            cur_compact=$(awk '/compact_stall/ {print $2}' /proc/vmstat)
            delta_compact=$((cur_compact - prev_compact))
            prev_compact=$cur_compact

            # IRQ counts per core (sum across all IRQ lines for cores 0-3)
            irq_cores=$(awk 'NR>1 && /^[[:space:]]*[0-9]+:/ {
                gsub(/:/, "", $1)
                c0+=$2; c1+=$3; c2+=$4; c3+=$5
            } END {
                printf "%d,%d,%d,%d", c0, c1, c2, c3
            }' /proc/interrupts 2>/dev/null || echo "0,0,0,0")

            # InnoDB dirty pages
            dirty=$(docker exec "$CONTAINER" mysql -uroot -p"$MYSQL_PASS" -h 127.0.0.1 -N \
                -e "SELECT variable_value FROM performance_schema.global_status WHERE variable_name='Innodb_buffer_pool_pages_dirty'" 2>/dev/null || echo 0)
            [[ -z "$dirty" ]] && dirty=0

            # Available memory
            mem_avail=$(awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo)

            echo "$ts,$cpu_data,$delta_ctxt,$rq0,$rq1,$rq2,$rq3,$delta_compact,$irq_cores,$dirty,$mem_avail"
        done
    ) > "$outfile" 2>/dev/null &
    MONITOR_PID=$!
}

hires_monitor_stop() {
    if [[ -n "$MONITOR_PID" ]]; then
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
        MONITOR_PID=""
    fi
}

# --- Hypothesis apply/revert ---

save_system_state() {
    ORIG_THP_ENABLED=$(cat /sys/kernel/mm/transparent_hugepage/enabled | grep -oP '\[\K[^\]]+')
    ORIG_THP_DEFRAG=$(cat /sys/kernel/mm/transparent_hugepage/defrag | grep -oP '\[\K[^\]]+')
    ORIG_NUMA_BALANCING=$(cat /proc/sys/kernel/numa_balancing)
    log "Saved system state: THP=$ORIG_THP_ENABLED, defrag=$ORIG_THP_DEFRAG, NUMA=$ORIG_NUMA_BALANCING"
}

apply_h1() {
    log "H1: Disabling THP + NUMA balancing"
    echo never > /sys/kernel/mm/transparent_hugepage/enabled
    echo never > /sys/kernel/mm/transparent_hugepage/defrag
    echo 0 > /proc/sys/kernel/numa_balancing
    # Verify
    log "  THP enabled: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
    log "  THP defrag:  $(cat /sys/kernel/mm/transparent_hugepage/defrag)"
    log "  NUMA bal:    $(cat /proc/sys/kernel/numa_balancing)"
}

revert_h1() {
    log "H1: Reverting THP + NUMA balancing"
    echo "$ORIG_THP_ENABLED" > /sys/kernel/mm/transparent_hugepage/enabled
    echo "$ORIG_THP_DEFRAG" > /sys/kernel/mm/transparent_hugepage/defrag
    echo "$ORIG_NUMA_BALANCING" > /proc/sys/kernel/numa_balancing
    log "  THP enabled: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
    log "  THP defrag:  $(cat /sys/kernel/mm/transparent_hugepage/defrag)"
    log "  NUMA bal:    $(cat /proc/sys/kernel/numa_balancing)"
}

apply_h2() {
    log "H2: CPU isolation via systemd slices + IRQ affinity"
    systemctl set-property --runtime system.slice AllowedCPUs="$NON_BENCH_CORES"
    systemctl set-property --runtime user.slice AllowedCPUs="$NON_BENCH_CORES"
    # Move IRQs off cores 0-3
    local moved=0
    for irqdir in /proc/irq/*/; do
        echo "$IRQ_MASK_ISOLATE" > "${irqdir}smp_affinity" 2>/dev/null && ((moved++)) || true
    done
    log "  system.slice: AllowedCPUs=$NON_BENCH_CORES"
    log "  user.slice:   AllowedCPUs=$NON_BENCH_CORES"
    log "  IRQs moved off cores 0-3: $moved IRQ lines"
}

revert_h2() {
    log "H2: Reverting CPU isolation + IRQ affinity"
    systemctl set-property --runtime system.slice AllowedCPUs="$TOTAL_CORES"
    systemctl set-property --runtime user.slice AllowedCPUs="$TOTAL_CORES"
    for irqdir in /proc/irq/*/; do
        echo "$IRQ_MASK_ALL" > "${irqdir}smp_affinity" 2>/dev/null || true
    done
    log "  system.slice: AllowedCPUs=$TOTAL_CORES"
    log "  user.slice:   AllowedCPUs=$TOTAL_CORES"
    log "  IRQs restored to all cores"
}

# --- Run benchmark phase ---

# Globals for collecting cross-phase results
declare -A PHASE_TPS PHASE_QPS PHASE_P99 PHASE_MAX

run_phase() {
    local phase_num="$1"
    local phase_name="$2"

    log "=========================================="
    log "=== PHASE $phase_num: $phase_name ==="
    log "=========================================="

    local tps_vals="" qps_vals="" p99_vals="" max_vals=""

    for run in $(seq 1 "$RUNS_PER_PHASE"); do
        log "--- Phase $phase_num, Run $run/$RUNS_PER_PHASE ---"

        # Verify container alive
        if ! docker inspect --format='{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
            die "Container died before phase $phase_num run $run!"
        fi

        # Start high-res monitor
        local mlog="${RESULTS_DIR}/phase_${phase_num}_run_${run}_hires_monitor.csv"
        hires_monitor_start "$mlog"

        # Run sysbench
        local raw="${RESULTS_DIR}/phase_${phase_num}_run_${run}_raw.txt"
        docker_exec sysbench \
            /usr/share/sysbench/oltp_read_write.lua \
            --mysql-host=127.0.0.1 --mysql-user=root --mysql-password="$MYSQL_PASS" \
            --mysql-db=sbtest --tables=$TABLES --table-size=$TABLE_SIZE \
            --threads=$THREADS --time=$DURATION \
            --percentile=99 --report-interval=$REPORT_INTERVAL \
            run 2>&1 | tee "$raw"

        # Stop monitor
        hires_monitor_stop

        # Parse results
        local tps qps lat_avg lat_p99 lat_max
        tps=$(grep "transactions:" "$raw" | awk -F'[()]' '{print $2}' | awk '{print $1}')
        qps=$(grep "queries:" "$raw" | awk -F'[()]' '{print $2}' | awk '{print $1}')
        lat_avg=$(awk '/Latency/,0' "$raw" | grep "avg:" | awk '{print $NF}')
        lat_p99=$(grep "99th percentile:" "$raw" | awk '{print $NF}')
        lat_max=$(awk '/Latency/,0' "$raw" | grep "max:" | awk '{print $NF}')

        log "Phase $phase_num Run $run: TPS=$tps QPS=$qps AvgLat=${lat_avg}ms P99=${lat_p99}ms MaxLat=${lat_max}ms"

        tps_vals="${tps_vals:+$tps_vals }$tps"
        qps_vals="${qps_vals:+$qps_vals }$qps"
        p99_vals="${p99_vals:+$p99_vals }$lat_p99"
        max_vals="${max_vals:+$max_vals }$lat_max"

        # Cooldown between runs
        if [[ $run -lt $RUNS_PER_PHASE ]]; then
            log "Cooldown 5s..."
            sleep 5
        fi
    done

    # Store phase results
    PHASE_TPS[$phase_num]="$tps_vals"
    PHASE_QPS[$phase_num]="$qps_vals"
    PHASE_P99[$phase_num]="$p99_vals"
    PHASE_MAX[$phase_num]="$max_vals"
}

# --- Phase 0: Preflight ---
log "=== PHASE 0: Preflight ==="
[[ $EUID -eq 0 ]] || die "Must run as root (sudo)"
command -v docker >/dev/null || die "docker not in PATH"
docker info >/dev/null 2>&1 || die "Docker daemon not running"
command -v mpstat >/dev/null || die "mpstat not found (install sysstat)"
mkdir -p "$RESULTS_DIR"
log "Results dir: $RESULTS_DIR"

# Save system state for later restoration
save_system_state

# --- Phase 1: Image + Container ---
log "=== PHASE 1: Image + Container Launch ==="

if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "Image $IMAGE already exists"
else
    log "Building image..."
    BDIR=$(mktemp -d)
    cat > "${BDIR}/Dockerfile" <<'DEOF'
FROM docker.io/library/mysql:8.0-debian
RUN apt-get update -qq && apt-get install -y --no-install-recommends sysbench procps \
    && rm -rf /var/lib/apt/lists/*
DEOF
    docker build -t "$IMAGE" "$BDIR"
    rm -rf "$BDIR"
    log "Image built"
fi

docker rm -f "$CONTAINER" 2>/dev/null || true

docker run -d \
    --name "$CONTAINER" \
    --cpuset-cpus="$PIN_CORES" \
    --cpus="$VCPUS" \
    --memory="${MEMORY_MB}m" \
    --env MYSQL_ROOT_PASSWORD="$MYSQL_PASS" \
    --tmpfs /var/lib/mysql:rw,size=3g \
    "$IMAGE" \
    --innodb-buffer-pool-size=1G \
    --innodb-flush-log-at-trx-commit=1 \
    --innodb-io-capacity=10000 \
    --innodb-io-capacity-max=20000

log "Container started: ${VCPUS} CPUs, ${MEMORY_MB}MiB, cores ${PIN_CORES}, tmpfs"

# Cleanup trap (also reverts system state)
cleanup_on_exit() {
    hires_monitor_stop
    # Revert any in-flight changes (safe to call even if already reverted)
    echo "$ORIG_THP_ENABLED" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo "$ORIG_THP_DEFRAG" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    echo "$ORIG_NUMA_BALANCING" > /proc/sys/kernel/numa_balancing 2>/dev/null || true
    systemctl set-property --runtime system.slice AllowedCPUs="$TOTAL_CORES" 2>/dev/null || true
    systemctl set-property --runtime user.slice AllowedCPUs="$TOTAL_CORES" 2>/dev/null || true
    for irqdir in /proc/irq/*/; do
        echo "$IRQ_MASK_ALL" > "${irqdir}smp_affinity" 2>/dev/null || true
    done
    docker rm -f "$CONTAINER" 2>/dev/null || true
    log "Cleanup complete — system state restored"
}
trap cleanup_on_exit EXIT

log "Waiting for MySQL..."
for i in $(seq 1 90); do
    if docker_exec mysqladmin ping -h 127.0.0.1 -uroot -p"$MYSQL_PASS" --silent 2>/dev/null; then
        log "MySQL ready (${i}s)"
        break
    fi
    [[ $i -eq 90 ]] && die "MySQL failed to start within 90s"
    sleep 1
done

# --- Phase 2: Sysbench Prepare + Warmup ---
log "=== PHASE 2: Sysbench Prepare + Warmup ==="

docker_exec mysql -uroot -p"$MYSQL_PASS" -h 127.0.0.1 \
    -e "CREATE DATABASE IF NOT EXISTS sbtest;"

docker_exec sysbench \
    /usr/share/sysbench/oltp_read_write.lua \
    --mysql-host=127.0.0.1 --mysql-user=root --mysql-password="$MYSQL_PASS" \
    --mysql-db=sbtest --tables=$TABLES --table-size=$TABLE_SIZE \
    prepare

log "Warmup: ${WARMUP}s throwaway run..."
docker_exec sysbench \
    /usr/share/sysbench/oltp_read_write.lua \
    --mysql-host=127.0.0.1 --mysql-user=root --mysql-password="$MYSQL_PASS" \
    --mysql-db=sbtest --tables=$TABLES --table-size=$TABLE_SIZE \
    --threads=$THREADS --time=$WARMUP \
    run >/dev/null 2>&1 || true
log "Warmup complete"

# --- Phase 3: Baseline ---
run_phase 3 "BASELINE (no fixes)"

# --- Phase 4: H1 -- THP off + NUMA off ---
apply_h1
run_phase 4 "H1: THP off + NUMA balancing off"
revert_h1
log "Phase 4 reverted — settling 5s..."
sleep 5

# --- Phase 5: H2 -- CPU isolation ---
apply_h2
run_phase 5 "H2: CPU isolation + IRQ affinity"
revert_h2
log "Phase 5 reverted — settling 5s..."
sleep 5

# --- Phase 6: H3 -- Combined ---
apply_h1
apply_h2
run_phase 6 "H3: Combined (THP off + CPU isolation)"
revert_h2
revert_h1
log "Phase 6 reverted"

# --- Phase 7: Cleanup ---
log "=== PHASE 7: Cleanup ==="
docker_exec sysbench \
    /usr/share/sysbench/oltp_read_write.lua \
    --mysql-host=127.0.0.1 --mysql-user=root --mysql-password="$MYSQL_PASS" \
    --mysql-db=sbtest --tables=$TABLES cleanup 2>/dev/null || true
# Container removed by EXIT trap

# --- Phase 8: Unified Report ---
log "=== PHASE 8: Generating Report ==="

REPORT="${RESULTS_DIR}/report.md"

phase_labels=("" "" "" "Baseline" "H1: THP off + NUMA off" "H2: CPU isolation + IRQ aff" "H3: Combined (H1+H2)")
phase_configs=("" "" "" "tmpfs, no fixes" "+THP off +NUMA off" "+CPU isolation +IRQ affinity" "Combined H1+H2")

{
cat <<HEADER
# Isolation Test - Docker TPS Variance Root Cause Analysis

**Date:** $(date '+%Y-%m-%d %H:%M:%S')
**Kernel:** $(uname -r) | **Host:** $(nproc) logical CPUs (8C/16T)
**Container:** ${VCPUS} CPUs | ${MEMORY_MB} MiB | Cores ${PIN_CORES} | tmpfs
**Workload:** sysbench oltp\_read\_write | ${TABLES}×${TABLE_SIZE} rows | ${THREADS} threads | ${DURATION}s/run
**Runs per phase:** ${RUNS_PER_PHASE} | **Total runs:** $((RUNS_PER_PHASE * 4))
**Saved system state:** THP=${ORIG_THP_ENABLED} | defrag=${ORIG_THP_DEFRAG} | NUMA=${ORIG_NUMA_BALANCING}

> Container stayed alive across all phases — only host tuning changed.
> MySQL buffer pool state is identical across phases, eliminating warmup confounds.

---

## Phase Comparison Summary

| Phase | Config | Mean TPS | CV | Mean P99 (ms) | Notes |
|-------|--------|---------|-----|----------|-------|
HEADER

for p in 3 4 5 6; do
    if [[ -n "${PHASE_TPS[$p]:-}" ]]; then
        s_tps=$(compute_stats "${PHASE_TPS[$p]}")
        s_p99=$(compute_stats "${PHASE_P99[$p]}")
        mean_tps=$(echo "$s_tps" | awk '{print $1}')
        cv_tps=$(echo "$s_tps" | awk '{printf "%.1f%%", $3}')
        mean_p99=$(echo "$s_p99" | awk '{print $1}')
        printf "| %s | %s | %s | %s | %s | |\n" \
            "${phase_labels[$p]}" "${phase_configs[$p]}" "$mean_tps" "$cv_tps" "$mean_p99"
    fi
done

printf "| Kata+FC (ref) | devmapper, microVM | %.2f | %.1f%% | %.2f | from previous bench |\n" \
    "$KATA_REF_TPS" "$KATA_REF_CV" "$KATA_REF_P99"

echo ""
echo "---"
echo ""

# Per-phase detailed tables
for p in 3 4 5 6; do
    if [[ -z "${PHASE_TPS[$p]:-}" ]]; then continue; fi

    echo "## Phase $p: ${phase_labels[$p]}"
    echo ""
    echo "**Config:** ${phase_configs[$p]}"
    echo ""

    # Per-run table
    read -ra tps_arr <<< "${PHASE_TPS[$p]}"
    read -ra qps_arr <<< "${PHASE_QPS[$p]}"
    read -ra p99_arr <<< "${PHASE_P99[$p]}"
    read -ra max_arr <<< "${PHASE_MAX[$p]}"

    echo "| Run | TPS | QPS | P99 (ms) | Max Lat (ms) |"
    echo "|-----|-----|-----|----------|-------------|"
    for i in "${!tps_arr[@]}"; do
        printf "| %d | %s | %s | %s | %s |\n" \
            $((i+1)) "${tps_arr[$i]}" "${qps_arr[$i]}" "${p99_arr[$i]}" "${max_arr[$i]}"
    done

    echo ""

    # Stats
    s_tps=$(compute_stats "${PHASE_TPS[$p]}")
    s_p99=$(compute_stats "${PHASE_P99[$p]}")
    echo "**TPS:** mean=$(echo "$s_tps" | awk '{print $1}'), stddev=$(echo "$s_tps" | awk '{print $2}'), CV=$(echo "$s_tps" | awk '{printf "%.1f%%", $3}')"
    echo "**P99:** mean=$(echo "$s_p99" | awk '{print $1}'), stddev=$(echo "$s_p99" | awk '{print $2}'), CV=$(echo "$s_p99" | awk '{printf "%.1f%%", $3}')"
    echo ""

    # Monitor summaries
    echo "<details>"
    echo "<summary>High-Resolution Monitor Summary</summary>"
    echo ""
    for run in $(seq 1 "$RUNS_PER_PHASE"); do
        mlog="${RESULTS_DIR}/phase_${p}_run_${run}_hires_monitor.csv"
        if [[ -f "$mlog" ]] && [[ $(wc -l < "$mlog") -gt 1 ]]; then
            echo "**Run $run:**"
            awk -F',' 'NR>1 {
                n++
                ctxt+=$22; if($22+0>mctxt) mctxt=$22
                cs+=$26; if($26+0>mcs) mcs=$26
                dirty+=$31; if($31+0>md) md=$31
            } END {
                if(n>0) {
                    printf "- Context switches/s: avg=%.0f, max=%.0f\n", ctxt/n, mctxt
                    printf "- Compaction stalls: total=%.0f, max/sample=%.0f\n", cs, mcs
                    printf "- InnoDB dirty pages: avg=%.0f, max=%.0f\n", dirty/n, md
                }
            }' "$mlog" 2>/dev/null || echo "- (monitor data parse error)"
            echo ""
        fi
    done
    echo "</details>"
    echo ""
    echo "---"
    echo ""
done

# Conclusion template
cat <<'CONCLUSION'
## Conclusion

### Variance Attribution

Examine the CV column in the Phase Comparison Summary:

1. **If H1 (THP off) has lower CV than Baseline** -- THP compaction is a significant source of jitter
2. **If H2 (CPU isolation) has lower CV than Baseline** -- Host daemon CPU contention causes variance
3. **If H3 (Combined) matches Kata+FC's CV** -- Docker variance is fully explained by lack of isolation
4. **If none reduce CV significantly** -- Variance source is elsewhere (MySQL internals, scheduler, etc.)

### Key Metrics to Compare

- **CV progression:** Baseline -> H1 -> H2 -> H3 -> Kata+FC (should converge if thesis is correct)
- **Mean TPS:** Should stay roughly constant (fixes reduce variance, not throughput)
- **Compaction stalls:** H1/H3 should show zero vs. Baseline

CONCLUSION

} > "$REPORT"

log "Report saved: $REPORT"
log "Done! Total phases: 4, Total runs: $((RUNS_PER_PHASE * 4))"
log "View report: cat $REPORT"
