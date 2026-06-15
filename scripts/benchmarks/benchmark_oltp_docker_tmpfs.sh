#!/usr/bin/env bash
# Docker MySQL OLTP Benchmark - tmpfs (RAM-backed, no disk I/O)
# 5-run sysbench oltp_read_write for direct comparison with Kata+FC benchmarks
set -euo pipefail

# --- Configuration ---
CONTAINER="mysql-bench-docker-tmpfs"
IMAGE="mysql-bench:local"
MYSQL_PASS="benchpass"
RUNS=5
TABLES=4
TABLE_SIZE=100000
THREADS=4
DURATION=60
WARMUP=30
REPORT_INTERVAL=10
RESULTS_DIR="./bench_docker_tmpfs_$(date +%Y%m%d_%H%M%S)"

# --- Resource Limits (match Kata+FC config for fair comparison) ---
VCPUS=4                  # CPUs allocated to the container
MEMORY_MB=4096           # Memory in MiB allocated to the container
PIN_CORES="0-3"          # Host cores to pin the container to
MIN_FREE_GB=2            # Minimum free space (GB) to continue

# --- Helpers ---
log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

docker_exec() {
    docker exec "$CONTAINER" "$@"
}

# Check host filesystem free space (GB)
check_host_free() {
    df -BG /var/lib/docker 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); printf "%.1f", $4}'
}

# --- Background System Monitor ---
# Captures disk I/O, CPU iowait, InnoDB internals, memory, CPU freq every 2s
MONITOR_PID=""

monitor_start() {
    local outfile="$1"
    (
        echo "timestamp,disk_util_pct,disk_await_ms,disk_wps,iowait_pct,dirty_pages,pending_fsyncs,mem_avail_mb,cpu_mhz"
        while true; do
            ts=$(date +%H:%M:%S)

            # Disk I/O: find the device backing /var/lib/docker, get iostat
            disk_line=$(iostat -xd 1 2 2>/dev/null | tail -n +4 | awk 'NF>=14 {line=$0} END {print line}')
            disk_util=$(echo "$disk_line" | awk '{print $NF}')          # %util (last field)
            disk_await=$(echo "$disk_line" | awk '{print $10}')         # await
            disk_wps=$(echo "$disk_line" | awk '{print $8}')            # w/s
            [[ -z "$disk_util" ]] && disk_util=0
            [[ -z "$disk_await" ]] && disk_await=0
            [[ -z "$disk_wps" ]] && disk_wps=0

            # CPU iowait from /proc/stat (field 6 = iowait)
            read -r _ usr nice sys idle iow _ < /proc/stat
            sleep 0.1
            read -r _ usr2 nice2 sys2 idle2 iow2 _ < /proc/stat
            d_total=$(( (usr2+nice2+sys2+idle2+iow2) - (usr+nice+sys+idle+iow) ))
            d_iow=$(( iow2 - iow ))
            if [[ $d_total -gt 0 ]]; then
                iowait_pct=$(awk -v d="$d_iow" -v t="$d_total" 'BEGIN {printf "%.1f", d/t*100}')
            else
                iowait_pct=0
            fi

            # InnoDB dirty pages + pending fsyncs
            dirty=$(docker exec "$CONTAINER" mysql -uroot -p"$MYSQL_PASS" -h 127.0.0.1 -N \
                -e "SELECT variable_value FROM performance_schema.global_status WHERE variable_name='Innodb_buffer_pool_pages_dirty'" 2>/dev/null || echo 0)
            pending=$(docker exec "$CONTAINER" mysql -uroot -p"$MYSQL_PASS" -h 127.0.0.1 -N \
                -e "SELECT variable_value FROM performance_schema.global_status WHERE variable_name='Innodb_data_pending_fsyncs'" 2>/dev/null || echo 0)
            [[ -z "$dirty" ]] && dirty=0
            [[ -z "$pending" ]] && pending=0

            # Available memory (MB)
            mem_avail=$(awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo)

            # CPU frequency (MHz) — average across pinned cores
            cpu_mhz=$(awk '/^cpu MHz/ {sum+=$4; n++} END {printf "%.0f", sum/n}' /proc/cpuinfo 2>/dev/null || echo 0)

            echo "$ts,$disk_util,$disk_await,$disk_wps,$iowait_pct,$dirty,$pending,$mem_avail,$cpu_mhz"
            sleep 2
        done
    ) > "$outfile" 2>/dev/null &
    MONITOR_PID=$!
}

monitor_stop() {
    if [[ -n "$MONITOR_PID" ]]; then
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
        MONITOR_PID=""
    fi
}

# Verify we are NOT running inside a VM (pure Docker on host kernel)
verify_docker_native() {
    log "Verifying pure Docker (no hypervisor)..."

    # No hypervisor must be running
    if pgrep -x firecracker >/dev/null 2>&1; then
        die "[FAIL] Firecracker process running -- kill it first for a clean baseline"
    fi
    if pgrep -x qemu-system-x86_64 >/dev/null 2>&1; then
        die "[FAIL] QEMU process running -- kill it first for a clean baseline"
    fi
    log "[OK] No hypervisor processes running (clean baseline)"

    # Verify container runtime is runc (not kata)
    local runtime
    runtime=$(docker inspect --format='{{.HostConfig.Runtime}}' "$CONTAINER" 2>/dev/null || echo "unknown")
    if [[ "$runtime" == "runc" || "$runtime" == "" || "$runtime" == "default" ]]; then
        DETECTED_RUNTIME="runc (native)"
        log "[OK] Container runtime: runc (native Docker)"
    elif [[ "$runtime" == *"kata"* ]]; then
        die "[FAIL] Container runtime is '$runtime' -- not a pure Docker benchmark!"
    else
        DETECTED_RUNTIME="$runtime"
        log "[WARN] Container runtime: $runtime (unexpected, proceeding)"
    fi

    # Detect storage driver
    DETECTED_STORAGE=$(docker info --format='{{.Driver}}' 2>/dev/null || echo "unknown")
    log "[OK] Docker storage driver: $DETECTED_STORAGE"

    # Verify container shares host kernel
    local container_kernel host_kernel
    container_kernel=$(docker_exec uname -r 2>/dev/null || echo "unknown")
    host_kernel=$(uname -r)
    if [[ "$container_kernel" == "$host_kernel" ]]; then
        log "[OK] Container kernel matches host: $host_kernel"
    else
        log "[WARN] Container kernel ($container_kernel) differs from host ($host_kernel)"
    fi
}

# Stats: prints "mean stddev cv min max" from space-separated values
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

fmt_row() {
    local label="$1" stats="$2"
    echo "$stats" | awk -v l="$label" '{printf "| %-18s | %12.2f | %10.2f | %8.1f%% | %12.2f | %12.2f |\n", l, $1, $2, $3, $4, $5}'
}

# --- Phase 0: Preflight ---
log "Phase 0: Preflight checks"
log "Mode: Docker + tmpfs (no disk I/O — RAM-backed MySQL data)"
command -v docker >/dev/null || die "docker not in PATH"
docker info >/dev/null 2>&1 || die "Docker daemon not running"
mkdir -p "$RESULTS_DIR"
log "Results dir: $RESULTS_DIR"
DETECTED_RUNTIME="pending"
DETECTED_STORAGE="pending"

# Cleanup trap
cleanup_on_exit() {
    docker rm -f "$CONTAINER" 2>/dev/null || true
    log "Cleaned up Docker container"
}
trap cleanup_on_exit EXIT

# --- Phase 1: Image ---
log "Phase 1: Preparing mysql-bench image"
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "Image already exists in Docker"
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

# --- Phase 2: Launch Container ---
log "Phase 2: Launching Docker container (tmpfs)"
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

log "Container started with ${VCPUS} CPUs, ${MEMORY_MB} MiB RAM, pinned to cores ${PIN_CORES}"
log "MySQL data on tmpfs (RAM)"

log "Waiting for MySQL..."
for i in $(seq 1 90); do
    if docker_exec mysqladmin ping -h 127.0.0.1 -uroot -p"$MYSQL_PASS" --silent 2>/dev/null; then
        log "MySQL ready (${i}s)"
        break
    fi
    [[ $i -eq 90 ]] && die "MySQL failed to start within 90s"
    sleep 1
done

# Verify we are running pure Docker, not Kata
verify_docker_native

# --- Phase 3: Sysbench Prepare ---
log "Phase 3: Preparing sysbench data"
docker_exec mysql -uroot -p"$MYSQL_PASS" -h 127.0.0.1 \
    -e "CREATE DATABASE IF NOT EXISTS sbtest;"

docker_exec sysbench \
    /usr/share/sysbench/oltp_read_write.lua \
    --mysql-host=127.0.0.1 --mysql-user=root --mysql-password="$MYSQL_PASS" \
    --mysql-db=sbtest --tables=$TABLES --table-size=$TABLE_SIZE \
    prepare

# --- Phase 4: Benchmark Runs ---
log "Phase 4: Running $RUNS iterations (${DURATION}s each)"

# sysbench 1.0.20 lacks --warmup
log "Warmup: running ${WARMUP}s throwaway iteration..."
docker_exec sysbench \
    /usr/share/sysbench/oltp_read_write.lua \
    --mysql-host=127.0.0.1 --mysql-user=root --mysql-password="$MYSQL_PASS" \
    --mysql-db=sbtest --tables=$TABLES --table-size=$TABLE_SIZE \
    --threads=$THREADS --time=$WARMUP \
    run >/dev/null 2>&1 || true
log "Warmup complete"

declare -a R_TPS R_QPS R_LAT_AVG R_LAT_P99 R_LAT_MAX R_LAT_MIN

for run in $(seq 1 $RUNS); do
    log "=== Run $run/$RUNS ==="

    # Check host free space before each run
    FREE_GB=$(check_host_free)
    log "Host free space: ${FREE_GB} GB"
    if awk -v f="$FREE_GB" -v m="$MIN_FREE_GB" 'BEGIN { exit !(f < m) }'; then
        log "ABORT: Only ${FREE_GB} GB free, need at least ${MIN_FREE_GB} GB"
        break
    fi

    # Start background system monitor
    MONITOR_LOG="${RESULTS_DIR}/run_${run}_monitor.csv"
    monitor_start "$MONITOR_LOG"
    log "System monitor started (disk I/O, iowait, InnoDB dirty pages, memory, CPU freq)"

    # Run sysbench (p99 percentile for tail latency focus)
    RAW="${RESULTS_DIR}/run_${run}_raw.txt"
    docker_exec sysbench \
        /usr/share/sysbench/oltp_read_write.lua \
        --mysql-host=127.0.0.1 --mysql-user=root --mysql-password="$MYSQL_PASS" \
        --mysql-db=sbtest --tables=$TABLES --table-size=$TABLE_SIZE \
        --threads=$THREADS --time=$DURATION \
        --percentile=99 --report-interval=$REPORT_INTERVAL \
        run 2>&1 | tee "$RAW"

    # Stop monitor
    monitor_stop

    # Parse sysbench output
    tps=$(grep "transactions:" "$RAW" | awk -F'[()]' '{print $2}' | awk '{print $1}')
    qps=$(grep "queries:" "$RAW" | awk -F'[()]' '{print $2}' | awk '{print $1}')
    lat_avg=$(awk '/Latency/,0' "$RAW" | grep "avg:" | awk '{print $NF}')
    lat_min=$(awk '/Latency/,0' "$RAW" | grep "min:" | awk '{print $NF}')
    lat_max=$(awk '/Latency/,0' "$RAW" | grep "max:" | awk '{print $NF}')
    lat_p99=$(grep "99th percentile:" "$RAW" | awk '{print $NF}')

    # Store
    R_TPS+=("$tps");       R_QPS+=("$qps")
    R_LAT_AVG+=("$lat_avg"); R_LAT_P99+=("$lat_p99")
    R_LAT_MAX+=("$lat_max"); R_LAT_MIN+=("$lat_min")

    log "Run $run: TPS=$tps QPS=$qps AvgLat=${lat_avg}ms P99=${lat_p99}ms"

    # Cooldown between runs
    if [[ $run -lt $RUNS ]]; then
        log "Cooldown 5s..."
        sleep 5
        # Re-verify container is still alive
        if ! docker inspect --format='{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
            die "Docker container died between runs!"
        fi
    fi
done

# --- Phase 5: Cleanup ---
log "Phase 5: Cleaning up"
docker_exec sysbench \
    /usr/share/sysbench/oltp_read_write.lua \
    --mysql-host=127.0.0.1 --mysql-user=root --mysql-password="$MYSQL_PASS" \
    --mysql-db=sbtest --tables=$TABLES cleanup 2>/dev/null || true

docker rm -f "$CONTAINER" 2>/dev/null || true

# --- Phase 6: Report ---
log "Phase 6: Generating markdown report"

REPORT="${RESULTS_DIR}/report.md"
COMPLETED_RUNS=${#R_TPS[@]}

if [[ $COMPLETED_RUNS -eq 0 ]]; then
    echo "# Benchmark ABORTED — no runs completed" > "$REPORT"
    echo "" >> "$REPORT"
    echo "Check host free space and system logs." >> "$REPORT"
    log "No runs completed. Report: $REPORT"
    exit 1
fi

# Compute all stats
S_TPS=$(compute_stats "${R_TPS[*]}")
S_QPS=$(compute_stats "${R_QPS[*]}")
S_LAT_AVG=$(compute_stats "${R_LAT_AVG[*]}")
S_LAT_P99=$(compute_stats "${R_LAT_P99[*]}")
S_LAT_MAX=$(compute_stats "${R_LAT_MAX[*]}")
S_LAT_MIN=$(compute_stats "${R_LAT_MIN[*]}")

{
cat <<HEADER
# MySQL OLTP Benchmark — Docker + tmpfs (Baseline)

**Date:** $(date '+%Y-%m-%d %H:%M:%S')
**Kernel:** $(uname -r) | **Host CPUs:** $(nproc)
**Container Resources:** ${VCPUS} CPUs | ${MEMORY_MB} MiB RAM | Pinned to cores ${PIN_CORES}
**Workload:** sysbench oltp\_read\_write
**Config:** ${TABLES} tables × ${TABLE_SIZE} rows | ${THREADS} threads | ${DURATION}s/run | ${WARMUP}s warmup
**Runs:** ${COMPLETED_RUNS} | **Runtime:** ${DETECTED_RUNTIME}
**Storage:** tmpfs (RAM-backed — zero disk I/O) | **Isolation:** None (shared host kernel)
**InnoDB Tuning:** buffer\_pool=1G | io\_capacity=10000/20000 | data on tmpfs

> **Note:** This is the Docker baseline — no hypervisor, no VM exits, no microVM overhead.
> Compare directly with Kata+Firecracker results using identical workload parameters.

---

## Per-Run Results

| Run | TPS | QPS | Min Lat (ms) | Avg Lat (ms) | P99 Lat (ms) | Max Lat (ms) |
|-----|-----|-----|-------------|-------------|-------------|-------------|
HEADER

for i in $(seq 0 $((COMPLETED_RUNS-1))); do
    printf "| %d | %s | %s | %s | %s | %s | %s |\n" \
        $((i+1)) "${R_TPS[$i]}" "${R_QPS[$i]}" "${R_LAT_MIN[$i]}" \
        "${R_LAT_AVG[$i]}" "${R_LAT_P99[$i]}" "${R_LAT_MAX[$i]}"
done

cat <<MID

---

## Aggregate Statistics (across ${COMPLETED_RUNS} runs)

| Metric             |         Mean |     StdDev |       CV |          Min |          Max |
|--------------------|-------------|-----------|---------|-------------|-------------|
MID

fmt_row "TPS"              "$S_TPS"
fmt_row "QPS"              "$S_QPS"
fmt_row "Min Latency (ms)" "$S_LAT_MIN"
fmt_row "Avg Latency (ms)" "$S_LAT_AVG"
fmt_row "P99 Latency (ms)" "$S_LAT_P99"
fmt_row "Max Latency (ms)" "$S_LAT_MAX"

cat <<MID2

### Tail Latency Observations

- **Worst P99 across all runs:** $(echo "${R_LAT_P99[*]}" | tr ' ' '\n' | sort -rn | head -1) ms
- **Worst Max latency across all runs:** $(echo "${R_LAT_MAX[*]}" | tr ' ' '\n' | sort -rn | head -1) ms
- **P99 variability (CV):** $(echo "$S_LAT_P99" | awk '{printf "%.1f%%", $3}') — $(echo "$S_LAT_P99" | awk '{if ($3 < 5) print "excellent consistency"; else if ($3 < 15) print "acceptable variability"; else print "HIGH variability — investigate"}')

---

## Comparison Notes

This Docker baseline measures MySQL OLTP performance **without any hypervisor overhead**.
When comparing with Kata+Firecracker results:

- **TPS/QPS delta** = overhead introduced by the microVM + virtio-mmio block I/O
- **Latency delta** = additional latency from VM exits (MSR, interrupt, NPF, HLT)
- **No VM-exit section** — Docker containers share the host kernel directly
- **Storage** — Docker uses ${DETECTED_STORAGE} (host filesystem), Kata+FC uses devmapper (block device)

MID2

# --- Diagnostic: System Monitor Analysis ---
echo "---"
echo ""
echo "## System Diagnostics (per-run)"
echo ""
echo "> Background monitor captured disk I/O, CPU iowait, InnoDB dirty pages,"
echo "> pending fsyncs, available memory, and CPU frequency every ~2s during each run."
echo "> Correlate timestamps with the sysbench \`--report-interval\` output above."
echo ""

for i in $(seq 0 $((COMPLETED_RUNS-1))); do
    MLOG="${RESULTS_DIR}/run_$((i+1))_monitor.csv"
    if [[ -f "$MLOG" ]] && [[ $(wc -l < "$MLOG") -gt 1 ]]; then
        echo "### Run $((i+1)) — System Monitor"
        echo ""
        echo '```'
        # Print header + all data rows
        column -t -s',' "$MLOG"
        echo '```'
        echo ""

        # Compute summary stats for key columns
        echo "**Summary:**"
        awk -F',' 'NR>1 && NF>=9 {
            n++
            # disk_util (col 2), disk_await (col 3), iowait (col 5), dirty (col 6)
            u+=$2; if($2+0>mu) mu=$2
            a+=$3; if($3+0>ma) ma=$3
            w+=$5; if($5+0>mw) mw=$5
            d+=$6; if($6+0>md) md=$6
            p+=$7; if($7+0>mp) mp=$7
        } END {
            if(n>0) {
                printf "- Disk %%util: avg=%.1f%%, max=%.1f%%\n", u/n, mu
                printf "- Disk await: avg=%.1fms, max=%.1fms\n", a/n, ma
                printf "- CPU iowait: avg=%.1f%%, max=%.1f%%\n", w/n, mw
                printf "- InnoDB dirty pages: avg=%.0f, max=%.0f\n", d/n, md
                printf "- Pending fsyncs: avg=%.0f, max=%.0f\n", p/n, mp
            }
        }' "$MLOG"
        echo ""
    fi
done



} > "$REPORT"

log "Report saved: $REPORT"
log "Done! View with: cat $REPORT"
