#!/usr/bin/env bash
# Kata+Firecracker MySQL OLTP Benchmark
# 5-run sysbench oltp_read_write with VM-exit tracking and statistical analysis
set -euo pipefail

# --- Configuration ---
CONTAINER="mysql-bench-fc"
IMAGE="docker.io/library/mysql-bench:local"
MYSQL_PASS="benchpass"
RUNS=5
TABLES=4
TABLE_SIZE=100000
THREADS=4
DURATION=60
WARMUP=30
REPORT_INTERVAL=10
RESULTS_DIR="./bench_$(date +%Y%m%d_%H%M%S)"
KVM_DIR="/sys/kernel/debug/kvm"

# --- Resource Limits ---
VCPUS=4                  # vCPUs allocated to the microVM
MEMORY_MB=4096           # Memory in MiB allocated to the microVM
PIN_CORES="0-3"          # Host cores to pin the Firecracker process to
MIN_FREE_GB=2            # Minimum free devmapper space (GB) to continue

# --- Helpers ---
log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

ctr_exec() {
    local id="$1"; shift
    sudo ctr tasks exec --exec-id "$id" "$CONTAINER" "$@"
}

read_kvm() { sudo cat "${KVM_DIR}/$1" 2>/dev/null || echo 0; }

snapshot_kvm() {
    echo "$(read_kvm exits) $(read_kvm io_exits) $(read_kvm mmio_exits) $(read_kvm irq_exits) $(read_kvm halt_exits) $(read_kvm signal_exits)"
}

# Check host filesystem free space (GB) on the containerd data partition
check_host_free() {
    df -BG /var/lib/containerd 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); printf "%.1f", $4}'
}

# Verify Kata config points to Firecracker (not QEMU)
verify_kata_fc_config() {
    log "Pre-launch: verifying Kata config targets Firecracker..."
    local conf_link="/opt/kata/share/defaults/kata-containers/configuration.toml"
    local real_conf
    real_conf=$(readlink -f "$conf_link" 2>/dev/null || echo "$conf_link")
    if [[ "$real_conf" == *"configuration-fc"* ]]; then
        log "[OK] configuration.toml -> $(basename "$real_conf") (Firecracker)"
    elif [[ "$real_conf" == *"configuration-qemu"* ]]; then
        die "[FAIL] configuration.toml -> $(basename "$real_conf") -- points to QEMU, not Firecracker!"
    else
        log "[WARN] configuration.toml -> $(basename "$real_conf") (unknown, proceeding)"
    fi
    # FC config must reference firecracker binary, not qemu
    if grep -q 'path.*=.*/firecracker' "$KATA_FC_CONF" 2>/dev/null; then
        log "[OK] FC config references firecracker binary"
    else
        die "[FAIL] FC config does not reference firecracker binary"
    fi
}

verify_firecracker() {
    log "Verifying Firecracker (not QEMU)..."

    if pgrep -x qemu-system-x86_64 >/dev/null 2>&1 || pgrep -f 'qemu.*kata' >/dev/null 2>&1; then
        die "[FAIL] QEMU process detected -- Kata fell back to QEMU!"
    fi
    log "[OK] No QEMU process detected"

    if ! pgrep -x firecracker >/dev/null 2>&1; then
        die "[FAIL] No firecracker process found"
    fi
    log "[OK] Firecracker process running"

    # Guest dmesg: virtio_mmio = FC, virtio_pci = QEMU
    local dmesg_out
    dmesg_out=$(ctr_exec "fc-verify" sh -c "dmesg 2>/dev/null | grep -i virtio" 2>/dev/null || true)
    if echo "$dmesg_out" | grep -qi "virtio_mmio"; then
        log "[OK] Guest confirms: virtio-mmio (Firecracker)"
    elif echo "$dmesg_out" | grep -qi "virtio.pci\|virtio_pci"; then
        die "[FAIL] Guest reports virtio-pci -- this is QEMU!"
    else
        log "[WARN] Could not detect virtio type from guest dmesg (non-fatal, FC process confirmed)"
    fi

    # Detect rootfs storage type inside guest
    DETECTED_STORAGE="unknown"
    local mount_info
    mount_info=$(ctr_exec "fs-check" sh -c "mount | grep ' / ' ; cat /proc/mounts 2>/dev/null | grep ' / '" 2>/dev/null || true)
    if echo "$mount_info" | grep -qi "virtio\|vd[a-z]\|pmem"; then
        DETECTED_STORAGE="block-device (virtio-mmio)"
        log "[OK] Guest rootfs: block-backed (virtio-mmio)"
    elif echo "$mount_info" | grep -qi "virtiofs\|9p\|tmpfs.*/$"; then
        DETECTED_STORAGE="filesystem-shared (virtio-fs/9p)"
        log "[WARN] Guest rootfs: filesystem-shared (virtio-fs or 9p) -- NOT block-backed"
    else
        DETECTED_STORAGE="block-device (presumed — FC only supports block)"
        log "[OK] Guest rootfs type could not be parsed, but FC only supports block devices"
    fi
    log "Detected storage: $DETECTED_STORAGE"
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
command -v firecracker >/dev/null || die "firecracker not in PATH"
command -v kata-runtime >/dev/null || die "kata-runtime not in PATH"
command -v ctr >/dev/null || die "ctr not in PATH"
command -v perf >/dev/null || die "perf not in PATH (needed for VM-exit root cause analysis)"
sudo dmsetup ls | grep -q devpool || die "devmapper pool 'devpool' not found"
sudo test -f "${KVM_DIR}/exits" || die "KVM exits counter not found at ${KVM_DIR}/exits"
mkdir -p "$RESULTS_DIR"
log "Results dir: $RESULTS_DIR"
DETECTED_STORAGE="pending"  # Will be set by verify_firecracker()

# Apply vCPU/memory limits by patching the Kata FC config directly
KATA_FC_CONF="/opt/kata/share/defaults/kata-containers/configuration-fc.toml"
KATA_FC_BACKUP="${KATA_FC_CONF}.bench-backup"
log "Patching Kata FC config: ${VCPUS} vCPUs, ${MEMORY_MB} MiB RAM"
sudo cp "$KATA_FC_CONF" "$KATA_FC_BACKUP"
sudo sed -i "s/^default_vcpus = .*/default_vcpus = ${VCPUS}/" "$KATA_FC_CONF"
sudo sed -i "s/^default_memory = .*/default_memory = ${MEMORY_MB}/" "$KATA_FC_CONF"
log "Original config backed up to ${KATA_FC_BACKUP}"

# Trap to restore config and clean up container on exit
cleanup_on_exit() {
    sudo ctr tasks kill -s SIGKILL "$CONTAINER" 2>/dev/null || true
    sudo ctr containers delete "$CONTAINER" 2>/dev/null || true
    sudo ctr snapshots --snapshotter devmapper rm "$CONTAINER" 2>/dev/null || true
    if [[ -f "$KATA_FC_BACKUP" ]]; then
        sudo mv "$KATA_FC_BACKUP" "$KATA_FC_CONF"
        log "Restored original Kata FC config"
    fi
}
trap cleanup_on_exit EXIT

# --- Phase 1: Image ---
log "Phase 1: Preparing mysql-bench image"
if sudo ctr images ls -q | grep -q "mysql-bench:local"; then
    log "Image already in containerd"
else
    log "Building image via Docker..."
    BDIR=$(mktemp -d)
    cat > "${BDIR}/Dockerfile" <<'DEOF'
FROM docker.io/library/mysql:8.0-debian
RUN apt-get update -qq && apt-get install -y --no-install-recommends sysbench procps \
    && rm -rf /var/lib/apt/lists/*
DEOF
    docker build -t mysql-bench:local "$BDIR"
    rm -rf "$BDIR"
    log "Exporting to containerd..."
    docker save mysql-bench:local > /tmp/mysql-bench.tar
    sudo ctr images import --snapshotter devmapper /tmp/mysql-bench.tar
    rm -f /tmp/mysql-bench.tar
    log "Image imported"
fi

# --- Phase 2: Launch VM ---
log "Phase 2: Launching Firecracker microVM"
sudo ctr tasks kill -s SIGKILL "$CONTAINER" 2>/dev/null || true
sudo ctr containers delete "$CONTAINER" 2>/dev/null || true
sudo ctr snapshots --snapshotter devmapper rm "$CONTAINER" 2>/dev/null || true

sudo ctr run -d \
    --snapshotter devmapper \
    --runtime io.containerd.kata.v2 \
    --env MYSQL_ROOT_PASSWORD="$MYSQL_PASS" \
    "$IMAGE" "$CONTAINER"

log "Pinning Firecracker to cores ${PIN_CORES}..."
sleep 2  # Let FC process fully start
FC_PIDS=$(pgrep -x firecracker 2>/dev/null || true)
if [[ -n "$FC_PIDS" ]]; then
    while read -r pid; do
        sudo taskset -apc "$PIN_CORES" "$pid" >/dev/null 2>&1 || true
    done <<< "$FC_PIDS"
    log "Pinned FC PID(s) [$(echo $FC_PIDS | tr '\n' ' ')] to cores $PIN_CORES"
else
    log "[WARN] Could not find firecracker PID for pinning (non-fatal)"
fi

log "Waiting for MySQL..."
for i in $(seq 1 90); do
    if ctr_exec "ready-${i}" mysqladmin ping -h 127.0.0.1 -uroot -p"$MYSQL_PASS" --silent 2>/dev/null; then
        log "MySQL ready (${i}s)"
        break
    fi
    [[ $i -eq 90 ]] && die "MySQL failed to start within 90s"
    sleep 1
done

# Verify Kata config and hypervisor
verify_kata_fc_config

# Verify FC (not QEMU) + detect storage type
verify_firecracker

# --- Phase 3: Sysbench Prepare ---
log "Phase 3: Preparing sysbench data"
ctr_exec "create-db" mysql -uroot -p"$MYSQL_PASS" -h 127.0.0.1 \
    -e "CREATE DATABASE IF NOT EXISTS sbtest;"

ctr_exec "sb-prepare" sysbench \
    /usr/share/sysbench/oltp_read_write.lua \
    --mysql-host=127.0.0.1 --mysql-user=root --mysql-password="$MYSQL_PASS" \
    --mysql-db=sbtest --tables=$TABLES --table-size=$TABLE_SIZE \
    prepare

# --- Phase 4: Benchmark Runs ---
log "Phase 4: Running $RUNS iterations (${DURATION}s each)"

# sysbench 1.0.20 lacks --warmup
log "Warmup: running ${WARMUP}s throwaway iteration..."
ctr_exec "sb-warmup" sysbench \
    /usr/share/sysbench/oltp_read_write.lua \
    --mysql-host=127.0.0.1 --mysql-user=root --mysql-password="$MYSQL_PASS" \
    --mysql-db=sbtest --tables=$TABLES --table-size=$TABLE_SIZE \
    --threads=$THREADS --time=$WARMUP \
    run >/dev/null 2>&1 || true
log "Warmup complete"

declare -a R_TPS R_QPS R_LAT_AVG R_LAT_P99 R_LAT_MAX R_LAT_MIN
declare -a R_EXITS R_IO R_MMIO R_IRQ R_HALT

for run in $(seq 1 $RUNS); do
    log "=== Run $run/$RUNS ==="

    # Check devmapper free space before each run
    FREE_GB=$(check_host_free)
    log "Host free space: ${FREE_GB} GB"
    if awk -v f="$FREE_GB" -v m="$MIN_FREE_GB" 'BEGIN { exit !(f < m) }'; then
        log "ABORT: Only ${FREE_GB} GB free, need at least ${MIN_FREE_GB} GB"
        break
    fi

    # KVM snapshot before
    read -r e0 e0_io e0_mm e0_irq e0_halt e0_sig <<< "$(snapshot_kvm)"

    # Start perf kvm stat recording in background
    PERF_DATA="${RESULTS_DIR}/run_${run}_perf.data"
    sudo perf kvm stat record -a -o "$PERF_DATA" &
    PERF_PID=$!
    sleep 1  # Let perf attach

    # Run sysbench (p99 percentile for tail latency focus)
    RAW="${RESULTS_DIR}/run_${run}_raw.txt"
    ctr_exec "sb-run-${run}" sysbench \
        /usr/share/sysbench/oltp_read_write.lua \
        --mysql-host=127.0.0.1 --mysql-user=root --mysql-password="$MYSQL_PASS" \
        --mysql-db=sbtest --tables=$TABLES --table-size=$TABLE_SIZE \
        --threads=$THREADS --time=$DURATION \
        --percentile=99 --report-interval=$REPORT_INTERVAL \
        run 2>&1 | tee "$RAW"

    # Stop perf recording
    sudo kill -INT "$PERF_PID" 2>/dev/null || true
    wait "$PERF_PID" 2>/dev/null || true
    sleep 1

    # Generate perf kvm stat report
    PERF_REPORT="${RESULTS_DIR}/run_${run}_vmexit_reasons.txt"
    sudo perf kvm -i "$PERF_DATA" stat report --stdio 2>&1 | tee "$PERF_REPORT"
    # Clean up large perf data file (keep only the text report)
    sudo rm -f "$PERF_DATA"

    # KVM snapshot after
    read -r e1 e1_io e1_mm e1_irq e1_halt e1_sig <<< "$(snapshot_kvm)"

    # Parse sysbench output
    tps=$(grep "transactions:" "$RAW" | awk -F'[()]' '{print $2}' | awk '{print $1}')
    qps=$(grep "queries:" "$RAW" | awk -F'[()]' '{print $2}' | awk '{print $1}')
    lat_avg=$(awk '/Latency/,0' "$RAW" | grep "avg:" | awk '{print $NF}')
    lat_min=$(awk '/Latency/,0' "$RAW" | grep "min:" | awk '{print $NF}')
    lat_max=$(awk '/Latency/,0' "$RAW" | grep "max:" | awk '{print $NF}')
    lat_p99=$(grep "99th percentile:" "$RAW" | awk '{print $NF}')

    # VM-exit deltas
    d_exits=$((e1 - e0))
    d_io=$((e1_io - e0_io))
    d_mm=$((e1_mm - e0_mm))
    d_irq=$((e1_irq - e0_irq))
    d_halt=$((e1_halt - e0_halt))

    # Store
    R_TPS+=("$tps");       R_QPS+=("$qps")
    R_LAT_AVG+=("$lat_avg"); R_LAT_P99+=("$lat_p99")
    R_LAT_MAX+=("$lat_max"); R_LAT_MIN+=("$lat_min")
    R_EXITS+=("$d_exits"); R_IO+=("$d_io"); R_MMIO+=("$d_mm")
    R_IRQ+=("$d_irq");    R_HALT+=("$d_halt")

    log "Run $run: TPS=$tps QPS=$qps AvgLat=${lat_avg}ms P99=${lat_p99}ms VMExits=$d_exits"

    # Cooldown between runs
    if [[ $run -lt $RUNS ]]; then
        log "Cooldown 5s..."
        sleep 5
        # Re-verify FC is still alive
        if ! pgrep -x firecracker >/dev/null 2>&1; then
            die "Firecracker process died between runs!"
        fi
    fi
done

# --- Phase 5: Cleanup ---
log "Phase 5: Cleaning up"
ctr_exec "sb-cleanup" sysbench \
    /usr/share/sysbench/oltp_read_write.lua \
    --mysql-host=127.0.0.1 --mysql-user=root --mysql-password="$MYSQL_PASS" \
    --mysql-db=sbtest --tables=$TABLES cleanup 2>/dev/null || true

sudo ctr tasks kill -s SIGKILL "$CONTAINER" 2>/dev/null || true
sudo ctr containers delete "$CONTAINER" 2>/dev/null || true
sudo ctr snapshots --snapshotter devmapper rm "$CONTAINER" 2>/dev/null || true

# --- Phase 6: Report ---
log "Phase 6: Generating markdown report"

REPORT="${RESULTS_DIR}/report.md"
COMPLETED_RUNS=${#R_TPS[@]}

if [[ $COMPLETED_RUNS -eq 0 ]]; then
    echo "# Benchmark ABORTED — no runs completed" > "$REPORT"
    echo "" >> "$REPORT"
    echo "Check devmapper free space and system logs." >> "$REPORT"
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
S_EXITS=$(compute_stats "${R_EXITS[*]}")
S_IO=$(compute_stats "${R_IO[*]}")
S_MMIO=$(compute_stats "${R_MMIO[*]}")
S_IRQ=$(compute_stats "${R_IRQ[*]}")
S_HALT=$(compute_stats "${R_HALT[*]}")

{
cat <<HEADER
# MySQL OLTP Benchmark — Kata + Firecracker

**Date:** $(date '+%Y-%m-%d %H:%M:%S')
**Kernel:** $(uname -r) | **Host CPUs:** $(nproc)
**VM Resources:** ${VCPUS} vCPUs | ${MEMORY_MB} MiB RAM | Pinned to cores ${PIN_CORES}
**Workload:** sysbench oltp\_read\_write
**Config:** ${TABLES} tables × ${TABLE_SIZE} rows | ${THREADS} threads | ${DURATION}s/run | ${WARMUP}s warmup
**Runs:** ${COMPLETED_RUNS} | **Hypervisor:** Firecracker (verified)
**Storage:** devmapper snapshotter | **Detected:** ${DETECTED_STORAGE}

> **Note:** VM-exit counts are read from \`/sys/kernel/debug/kvm/\` global counters.
> Ensure no other KVM workloads run during the benchmark for accurate counts.

---

## Per-Run Results

| Run | TPS | QPS | Min Lat (ms) | Avg Lat (ms) | P99 Lat (ms) | Max Lat (ms) | VM Exits |
|-----|-----|-----|-------------|-------------|-------------|-------------|----------|
HEADER

for i in $(seq 0 $((COMPLETED_RUNS-1))); do
    printf "| %d | %s | %s | %s | %s | %s | %s | %s |\n" \
        $((i+1)) "${R_TPS[$i]}" "${R_QPS[$i]}" "${R_LAT_MIN[$i]}" \
        "${R_LAT_AVG[$i]}" "${R_LAT_P99[$i]}" "${R_LAT_MAX[$i]}" "${R_EXITS[$i]}"
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

## VM-Exit Analysis

| Exit Type          |         Mean |     StdDev |       CV |          Min |          Max |
|--------------------|-------------|-----------|---------|-------------|-------------|
MID2

fmt_row "Total Exits"  "$S_EXITS"
fmt_row "I/O Exits"    "$S_IO"
fmt_row "MMIO Exits"   "$S_MMIO"
fmt_row "IRQ Exits"    "$S_IRQ"
fmt_row "Halt Exits"   "$S_HALT"

cat <<MID3

### VM-Exit Breakdown (per-run)

| Run | Total | I/O | MMIO | IRQ | Halt |
|-----|-------|-----|------|-----|------|
MID3

for i in $(seq 0 $((COMPLETED_RUNS-1))); do
    printf "| %d | %s | %s | %s | %s | %s |\n" \
        $((i+1)) "${R_EXITS[$i]}" "${R_IO[$i]}" "${R_MMIO[$i]}" "${R_IRQ[$i]}" "${R_HALT[$i]}"
done

cat <<FOOTER

---

## Exits-per-Transaction

| Run | Exits/TPS |
|-----|-----------|
FOOTER

for i in $(seq 0 $((COMPLETED_RUNS-1))); do
    awk -v e="${R_EXITS[$i]}" -v t="${R_TPS[$i]}" -v d="$DURATION" -v r="$((i+1))" \
        'BEGIN { total_tx = t * d; ratio = (total_tx > 0) ? e / total_tx : 0; printf "| %d | %.2f |\n", r, ratio }'
done

cat <<RCA_HDR

---

## VM-Exit Root Cause Analysis

> Exit reasons captured via \`perf kvm stat\` — shows Intel VMX exit reason codes,
> sample counts, and time spent handling each exit type.

RCA_HDR

for i in $(seq 0 $((COMPLETED_RUNS-1))); do
    PERF_REPORT="${RESULTS_DIR}/run_$((i+1))_vmexit_reasons.txt"
    if [[ -f "$PERF_REPORT" ]]; then
        echo "### Run $((i+1))"
        echo ""
        echo '```'
        # Print the header and data lines from perf kvm stat report
        awk '
            /VM-EXIT/ { found=1 }
            found { print }
            /^Total/ { found=0; print ""; }
        ' "$PERF_REPORT"
        echo '```'
        echo ""
    fi
done

# Aggregate: top exit reasons across all runs
echo "### Aggregated Top Exit Reasons"
echo ""
echo "| Exit Reason | Total Samples | Avg Samples/Run | Avg Time (us) |"
echo "|-------------|--------------|-----------------|---------------|"

# Parse all perf reports and aggregate
for i in $(seq 1 $COMPLETED_RUNS); do
    cat "${RESULTS_DIR}/run_${i}_vmexit_reasons.txt" 2>/dev/null
done | awk '
    /VM-EXIT/ { header=1; next }
    /^Total/ { header=0; next }
    /^$/ { next }
    header && NF >= 4 {
        reason = $1
        samples = $2
        # Avg time is field $7 (e.g. "5.97us") in perf kvm stat output
        avg_time = $7
        gsub(/us/, "", avg_time)
        total_samples[reason] += samples
        total_time[reason] += avg_time
        count[reason]++
        if (!(reason in seen)) { seen[reason]=1; keys[++nk]=reason }
    }
    END {
        # Bubble sort keys by total_samples descending
        for (x = 1; x <= nk; x++)
            for (y = x+1; y <= nk; y++)
                if (total_samples[keys[x]] < total_samples[keys[y]]) {
                    tmp = keys[x]; keys[x] = keys[y]; keys[y] = tmp
                }
        for (x = 1; x <= nk; x++) {
            r = keys[x]
            avg_s = total_samples[r] / count[r]
            avg_t = total_time[r] / count[r]
            printf "| %-25s | %12d | %15.0f | %13.2f |\n", r, total_samples[r], avg_s, avg_t
        }
    }
'

echo ""
echo "_Raw sysbench output and perf VM-exit reports for each run are saved in \`${RESULTS_DIR}/\`._"

} > "$REPORT"

log "Report saved: $REPORT"
log "Done! View with: cat $REPORT"
