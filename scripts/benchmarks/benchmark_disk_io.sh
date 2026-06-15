#!/usr/bin/env bash
# Disk I/O Benchmark - Kata+FC (devmapper) vs Docker (disk volume)
# fio-based, replicating CLOSER 2021 methodology (Section 3.1.5)
# Usage: sudo bash benchmark_disk_io.sh
set -euo pipefail

# --- Configuration ---
KATA_CONTAINER="fio-bench-fc"
DOCKER_CONTAINER="fio-bench-docker"
DOCKER_IMAGE="fio-bench:local"
CTR_IMAGE="docker.io/library/fio-bench:local"
DATA_VOLUME="fio-bench-data"
RUNS=3
RESULTS_DIR="./bench_diskio_$(date +%Y%m%d_%H%M%S)"
KVM_DIR="/sys/kernel/debug/kvm"

# --- Resource Limits (match existing OLTP scripts) ---
VCPUS=4
MEMORY_MB=4096
PIN_CORES="0-3"

# fio parameters (CLOSER 2021 methodology)
BLOCK_SIZES=(16k 64k 256k 1m)
IO_TYPES=(read write randread randwrite)
FILE_SIZE="2G"         # Max safe within 4GB devmapper slice
RUNTIME=20             # Seconds per test (20s gives thousands of I/O samples)
COOLDOWN=3             # Seconds between runs (let I/O queue drain)
IODEPTH=16             # Queue depth

# --- Kata FC Config ---
KATA_FC_CONF="/opt/kata/share/defaults/kata-containers/configuration-fc.toml"
KATA_FC_BACKUP="${KATA_FC_CONF}.bench-backup"

# --- Helpers ---
log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

ctr_exec() {
    local id="$1"; shift
    sudo ctr tasks exec --exec-id "$id" "$KATA_CONTAINER" "$@"
}

docker_exec() {
    docker exec "$DOCKER_CONTAINER" "$@"
}

read_kvm() { sudo cat "${KVM_DIR}/$1" 2>/dev/null || echo 0; }

snapshot_kvm() {
    echo "$(read_kvm exits) $(read_kvm io_exits) $(read_kvm mmio_exits) $(read_kvm irq_exits) $(read_kvm halt_exits) $(read_kvm signal_exits)"
}

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

# Parse fio JSON output -> "lat_mean_us lat_std_us bw_kib iops lat_min_us lat_max_us"
parse_fio_json() {
    local json_file="$1" rw_type="$2"
    python3 -c "
import json, sys
with open('${json_file}') as f:
    data = json.load(f)
job = data['jobs'][0]
key = 'read' if 'read' in '${rw_type}' else 'write'
lat = job[key]['lat_ns']
mean_us = lat['mean'] / 1000
stddev_us = lat['stddev'] / 1000
min_us = lat['min'] / 1000
max_us = lat['max'] / 1000
bw = job[key]['bw']
iops = job[key]['iops']
print(f'{mean_us:.2f} {stddev_us:.2f} {bw:.2f} {iops:.2f} {min_us:.2f} {max_us:.2f}')
"
}

# --- Verification ---

verify_kata_fc_config() {
    log "Verifying Kata config targets Firecracker..."
    local conf_link="/opt/kata/share/defaults/kata-containers/configuration.toml"
    local real_conf
    real_conf=$(readlink -f "$conf_link" 2>/dev/null || echo "$conf_link")
    if [[ "$real_conf" == *"configuration-fc"* ]]; then
        log "[OK] configuration.toml -> $(basename "$real_conf") (Firecracker)"
    elif [[ "$real_conf" == *"configuration-qemu"* ]]; then
        die "[FAIL] configuration.toml -> $(basename "$real_conf") -- points to QEMU!"
    else
        log "[WARN] configuration.toml -> $(basename "$real_conf") (unknown, proceeding)"
    fi
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
    local dmesg_out
    dmesg_out=$(ctr_exec "fc-verify" sh -c "dmesg 2>/dev/null | grep -i virtio" 2>/dev/null || true)
    if echo "$dmesg_out" | grep -qi "virtio_mmio"; then
        log "[OK] Guest confirms: virtio-mmio (Firecracker)"
    elif echo "$dmesg_out" | grep -qi "virtio.pci\|virtio_pci"; then
        die "[FAIL] Guest reports virtio-pci -- this is QEMU!"
    else
        log "[WARN] Could not detect virtio type (non-fatal, FC process confirmed)"
    fi
}

verify_docker_native() {
    log "Verifying pure Docker (no hypervisor)..."
    if pgrep -x firecracker >/dev/null 2>&1; then
        die "[FAIL] Firecracker process running -- kill it first"
    fi
    if pgrep -x qemu-system-x86_64 >/dev/null 2>&1; then
        die "[FAIL] QEMU process running -- kill it first"
    fi
    log "[OK] No hypervisor processes running"
    local runtime
    runtime=$(docker inspect --format='{{.HostConfig.Runtime}}' "$DOCKER_CONTAINER" 2>/dev/null || echo "unknown")
    if [[ "$runtime" == "runc" || "$runtime" == "" || "$runtime" == "default" ]]; then
        log "[OK] Container runtime: runc (native Docker)"
    elif [[ "$runtime" == *"kata"* ]]; then
        die "[FAIL] Container runtime is '$runtime' -- not a pure Docker benchmark!"
    else
        log "[WARN] Container runtime: $runtime (unexpected, proceeding)"
    fi
    DETECTED_STORAGE=$(docker info --format='{{.Driver}}' 2>/dev/null || echo "unknown")
    log "[OK] Docker storage driver: $DETECTED_STORAGE"
}

# Cleanup on exit
cleanup_on_exit() {
    sudo ctr tasks kill -s SIGKILL "$KATA_CONTAINER" 2>/dev/null || true
    sudo ctr containers delete "$KATA_CONTAINER" 2>/dev/null || true
    sudo ctr snapshots --snapshotter devmapper rm "$KATA_CONTAINER" 2>/dev/null || true
    if [[ -f "$KATA_FC_BACKUP" ]]; then
        sudo mv "$KATA_FC_BACKUP" "$KATA_FC_CONF"
        log "Restored original Kata FC config"
    fi
    docker rm -f "$DOCKER_CONTAINER" 2>/dev/null || true
    docker volume rm "$DATA_VOLUME" 2>/dev/null || true
}
trap cleanup_on_exit EXIT

# --- Phase 0: Preflight ---
log "Phase 0: Preflight checks"
command -v firecracker >/dev/null || die "firecracker not in PATH"
command -v kata-runtime >/dev/null || die "kata-runtime not in PATH"
command -v ctr >/dev/null || die "ctr not in PATH"
command -v docker >/dev/null || die "docker not in PATH"
command -v python3 >/dev/null || die "python3 not in PATH (needed for JSON parsing)"
sudo dmsetup ls | grep -q devpool || die "devmapper pool 'devpool' not found"
sudo test -f "${KVM_DIR}/exits" || die "KVM exits counter not found at ${KVM_DIR}/exits"
mkdir -p "$RESULTS_DIR"
log "Results dir: $RESULTS_DIR"

# Initialize CSV headers
echo "bs,rw,run,lat_mean_us,lat_std_us,bw_kib,iops,lat_min_us,lat_max_us,vm_exits" \
    > "${RESULTS_DIR}/kata_results.csv"
echo "bs,rw,run,lat_mean_us,lat_std_us,bw_kib,iops,lat_min_us,lat_max_us" \
    > "${RESULTS_DIR}/docker_results.csv"

# --- Phase 1: Build Image ---
log "Phase 1: Building fio-bench image"
if docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
    log "Docker image already exists"
else
    log "Building lightweight fio image..."
    BDIR=$(mktemp -d)
    cat > "${BDIR}/Dockerfile" <<'DEOF'
FROM debian:bookworm-slim
RUN apt-get update -qq && apt-get install -y --no-install-recommends fio procps \
    && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
DEOF
    docker build -t "$DOCKER_IMAGE" "$BDIR"
    rm -rf "$BDIR"
    log "Image built"
fi

if sudo ctr images ls -q | grep -q "fio-bench:local"; then
    log "Containerd image already exists"
else
    log "Exporting to containerd..."
    docker save "$DOCKER_IMAGE" > /tmp/fio-bench.tar
    sudo ctr images import --snapshotter devmapper /tmp/fio-bench.tar
    rm -f /tmp/fio-bench.tar
    log "Image imported"
fi

# --- Phase 2: Docker (disk) Benchmark ---
log "Phase 2: Docker (disk volume) Disk I/O Benchmark"

verify_docker_native_preflight() {
    if pgrep -x firecracker >/dev/null 2>&1; then
        die "Firecracker process running — kill it or reboot first for a clean Docker baseline"
    fi
    if pgrep -x qemu-system-x86_64 >/dev/null 2>&1; then
        die "QEMU process running — kill it first for a clean Docker baseline"
    fi
    log "[OK] No hypervisor processes running (clean baseline)"
}
verify_docker_native_preflight


docker rm -f "$DOCKER_CONTAINER" 2>/dev/null || true
docker volume rm "$DATA_VOLUME" 2>/dev/null || true
docker volume create "$DATA_VOLUME" >/dev/null

docker run -d \
    --name "$DOCKER_CONTAINER" \
    --cpuset-cpus="$PIN_CORES" \
    --cpus="$VCPUS" \
    --memory="${MEMORY_MB}m" \
    -v "${DATA_VOLUME}:/data" \
    "$DOCKER_IMAGE"

log "Container started: ${VCPUS} CPUs, ${MEMORY_MB} MiB, cores ${PIN_CORES}"
sleep 2
docker_exec fio --version || die "fio not available in Docker container"
verify_docker_native

# Run fio benchmarks
DOCKER_FIO_FILE="/data/fio-testfile"

for bs in "${BLOCK_SIZES[@]}"; do
    log "=== Docker: Block size $bs ==="

    # Precreate test file
    log "Precreating ${FILE_SIZE} test file on Docker volume..."
    docker_exec fio \
        --name=precreate --filename="$DOCKER_FIO_FILE" --size="$FILE_SIZE" \
        --rw=write --bs=1m --direct=1 --ioengine=libaio --iodepth=16 \
        >/dev/null 2>&1

    for rw in "${IO_TYPES[@]}"; do
        for run in $(seq 1 $RUNS); do
            log "  bs=$bs rw=$rw run=$run/$RUNS"

            JSON_FILE="${RESULTS_DIR}/docker_${bs}_${rw}_run${run}.json"
            docker_exec fio \
                --name=diskio \
                --filename="$DOCKER_FIO_FILE" \
                --size="$FILE_SIZE" \
                --rw="$rw" \
                --bs="$bs" \
                --direct=1 \
                --ioengine=libaio \
                --iodepth="$IODEPTH" \
                --numjobs=1 \
                --runtime="$RUNTIME" \
                --time_based \
                --group_reporting \
                --output-format=json \
                > "$JSON_FILE" 2>/dev/null

            metrics=$(parse_fio_json "$JSON_FILE" "$rw")
            read -r lat_mean lat_std bw iops lat_min lat_max <<< "$metrics"

            echo "$bs,$rw,$run,$lat_mean,$lat_std,$bw,$iops,$lat_min,$lat_max" \
                >> "${RESULTS_DIR}/docker_results.csv"

            log "    lat=${lat_mean}us bw=${bw}KiB/s iops=${iops}"
            sleep $COOLDOWN
        done
    done

    docker_exec rm -f "$DOCKER_FIO_FILE" 2>/dev/null || true
done

# Cleanup Docker
docker rm -f "$DOCKER_CONTAINER" 2>/dev/null || true
docker volume rm "$DATA_VOLUME" 2>/dev/null || true
log "Docker phase complete"

log "Cooldown 10s before Kata+FC phase..."
sleep 10

# --- Phase 3: Kata+FC Benchmark ---
log "Phase 3: Kata+FC Disk I/O Benchmark"


log "Patching Kata FC config: ${VCPUS} vCPUs, ${MEMORY_MB} MiB RAM"
sudo cp "$KATA_FC_CONF" "$KATA_FC_BACKUP"
sudo sed -i "s/^default_vcpus = .*/default_vcpus = ${VCPUS}/" "$KATA_FC_CONF"
sudo sed -i "s/^default_memory = .*/default_memory = ${MEMORY_MB}/" "$KATA_FC_CONF"
log "Original config backed up to ${KATA_FC_BACKUP}"

verify_kata_fc_config

# Launch Kata container
sudo ctr tasks kill -s SIGKILL "$KATA_CONTAINER" 2>/dev/null || true
sudo ctr containers delete "$KATA_CONTAINER" 2>/dev/null || true
sudo ctr snapshots --snapshotter devmapper rm "$KATA_CONTAINER" 2>/dev/null || true

sudo ctr run -d \
    --snapshotter devmapper \
    --runtime io.containerd.kata.v2 \
    "$CTR_IMAGE" "$KATA_CONTAINER"


log "Pinning Firecracker to cores ${PIN_CORES}..."
sleep 3
FC_PIDS=$(pgrep -x firecracker 2>/dev/null || true)
if [[ -n "$FC_PIDS" ]]; then
    while read -r pid; do
        sudo taskset -apc "$PIN_CORES" "$pid" >/dev/null 2>&1 || true
    done <<< "$FC_PIDS"
    log "[OK] Pinned FC PID(s) [$(echo $FC_PIDS | tr '\n' ' ')] to cores $PIN_CORES"
else
    log "[WARN] Could not find firecracker PID for pinning (non-fatal)"
fi

sleep 2
ctr_exec "check-fio" fio --version || die "fio not available in Kata container"
verify_firecracker

# Run fio benchmarks
KATA_FIO_FILE="/tmp/fio-testfile"
EXEC_CTR=0

for bs in "${BLOCK_SIZES[@]}"; do
    log "=== Kata+FC: Block size $bs ==="

    # Precreate test file for read tests
    EXEC_CTR=$((EXEC_CTR + 1))
    log "Precreating ${FILE_SIZE} test file on devmapper rootfs..."
    ctr_exec "pre-${EXEC_CTR}" fio \
        --name=precreate --filename="$KATA_FIO_FILE" --size="$FILE_SIZE" \
        --rw=write --bs=1m --direct=1 --ioengine=libaio --iodepth=16 \
        >/dev/null 2>&1

    for rw in "${IO_TYPES[@]}"; do
        for run in $(seq 1 $RUNS); do
            EXEC_CTR=$((EXEC_CTR + 1))
            log "  bs=$bs rw=$rw run=$run/$RUNS"

            # KVM exit snapshot before
            read -r e0 e0_io e0_mm e0_irq e0_halt e0_sig <<< "$(snapshot_kvm)"

            # Run fio
            JSON_FILE="${RESULTS_DIR}/kata_${bs}_${rw}_run${run}.json"
            ctr_exec "fio-${EXEC_CTR}" fio \
                --name=diskio \
                --filename="$KATA_FIO_FILE" \
                --size="$FILE_SIZE" \
                --rw="$rw" \
                --bs="$bs" \
                --direct=1 \
                --ioengine=libaio \
                --iodepth="$IODEPTH" \
                --numjobs=1 \
                --runtime="$RUNTIME" \
                --time_based \
                --group_reporting \
                --output-format=json \
                > "$JSON_FILE" 2>/dev/null

            # KVM exit snapshot after
            read -r e1 e1_io e1_mm e1_irq e1_halt e1_sig <<< "$(snapshot_kvm)"
            d_exits=$((e1 - e0))

            # Parse results
            metrics=$(parse_fio_json "$JSON_FILE" "$rw")
            read -r lat_mean lat_std bw iops lat_min lat_max <<< "$metrics"

            # Append to CSV
            echo "$bs,$rw,$run,$lat_mean,$lat_std,$bw,$iops,$lat_min,$lat_max,$d_exits" \
                >> "${RESULTS_DIR}/kata_results.csv"

            log "    lat=${lat_mean}us bw=${bw}KiB/s iops=${iops} vmexits=${d_exits}"
            sleep $COOLDOWN
        done
    done

    # Clean up test file after each block size
    EXEC_CTR=$((EXEC_CTR + 1))
    ctr_exec "rm-${EXEC_CTR}" rm -f "$KATA_FIO_FILE" 2>/dev/null || true
done

# FC process may linger until reboot
log "Cleaning up Kata+FC container..."
sudo ctr tasks kill -s SIGKILL "$KATA_CONTAINER" 2>/dev/null || true
sudo ctr containers delete "$KATA_CONTAINER" 2>/dev/null || true
sudo ctr snapshots --snapshotter devmapper rm "$KATA_CONTAINER" 2>/dev/null || true
if [[ -f "$KATA_FC_BACKUP" ]]; then
    sudo mv "$KATA_FC_BACKUP" "$KATA_FC_CONF"
    log "Restored Kata FC config"
    KATA_FC_BACKUP=""  # Prevent double-restore in trap
fi
log "Kata+FC phase complete"

# --- Phase 4: Report ---
log "Phase 4: Generating comparison report"
REPORT="${RESULTS_DIR}/report.md"

{
cat <<HEADER
# Disk I/O Benchmark — Kata+FC (devmapper) vs Docker (disk volume)

**Date:** $(date '+%Y-%m-%d %H:%M:%S')
**Kernel:** $(uname -r) | **Host CPUs:** $(nproc)
**Resources:** ${VCPUS} vCPUs | ${MEMORY_MB} MiB RAM | Pinned to cores ${PIN_CORES}
**Tool:** fio | **ioengine:** libaio | **iodepth:** ${IODEPTH} | **direct:** 1 (O\_DIRECT)
**File size:** ${FILE_SIZE} | **Runtime:** ${RUNTIME}s/test | **Runs:** ${RUNS}
**Block sizes:** ${BLOCK_SIZES[*]}
**I/O types:** ${IO_TYPES[*]}

> **Kata+FC storage:** devmapper snapshotter (virtio-mmio block device)
> **Docker storage:** named volume on host filesystem (overlay2 driver)

---
HEADER

# Generate tables for each I/O type
for rw in "${IO_TYPES[@]}"; do
    # Human-readable names
    case "$rw" in
        read)      rw_name="Sequential Read" ;;
        write)     rw_name="Sequential Write" ;;
        randread)  rw_name="Random Read" ;;
        randwrite) rw_name="Random Write" ;;
    esac

    echo "## ${rw_name}"
    echo ""
    echo "### Latency (μs)"
    echo ""
    echo "| Block Size | Kata+FC Mean | Kata+FC StdDev | Docker Mean | Docker StdDev |"
    echo "|------------|-------------|---------------|------------|--------------|"

    for bs in "${BLOCK_SIZES[@]}"; do
        # Compute Kata stats
        kata_vals=$(awk -F',' -v b="$bs" -v r="$rw" '$1==b && $2==r {printf "%s ", $4}' \
            "${RESULTS_DIR}/kata_results.csv")
        kata_stats=$(compute_stats "$kata_vals")
        kata_mean=$(echo "$kata_stats" | awk '{printf "%.2f", $1}')
        kata_std=$(echo "$kata_stats" | awk '{printf "%.2f", $2}')

        # Compute Docker stats
        docker_vals=$(awk -F',' -v b="$bs" -v r="$rw" '$1==b && $2==r {printf "%s ", $4}' \
            "${RESULTS_DIR}/docker_results.csv")
        docker_stats=$(compute_stats "$docker_vals")
        docker_mean=$(echo "$docker_stats" | awk '{printf "%.2f", $1}')
        docker_std=$(echo "$docker_stats" | awk '{printf "%.2f", $2}')

        printf "| %-10s | %11s | %13s | %10s | %12s |\n" \
            "$bs" "$kata_mean" "$kata_std" "$docker_mean" "$docker_std"
    done

    echo ""
    echo "### Bandwidth (MiB/s)"
    echo ""
    echo "| Block Size | Kata+FC | Docker | Δ (%) |"
    echo "|------------|---------|--------|-------|"

    for bs in "${BLOCK_SIZES[@]}"; do
        kata_bw_vals=$(awk -F',' -v b="$bs" -v r="$rw" '$1==b && $2==r {printf "%s ", $6}' \
            "${RESULTS_DIR}/kata_results.csv")
        kata_bw_mean=$(compute_stats "$kata_bw_vals" | awk '{printf "%.2f", $1/1024}')

        docker_bw_vals=$(awk -F',' -v b="$bs" -v r="$rw" '$1==b && $2==r {printf "%s ", $6}' \
            "${RESULTS_DIR}/docker_results.csv")
        docker_bw_mean=$(compute_stats "$docker_bw_vals" | awk '{printf "%.2f", $1/1024}')

        delta=$(awk -v k="$kata_bw_mean" -v d="$docker_bw_mean" \
            'BEGIN { if (d > 0) printf "%.1f", (k-d)/d*100; else print "N/A" }')

        printf "| %-10s | %7s | %6s | %5s |\n" "$bs" "$kata_bw_mean" "$docker_bw_mean" "$delta"
    done

    echo ""
    echo "### IOPS"
    echo ""
    echo "| Block Size | Kata+FC | Docker | Δ (%) |"
    echo "|------------|---------|--------|-------|"

    for bs in "${BLOCK_SIZES[@]}"; do
        kata_iops_vals=$(awk -F',' -v b="$bs" -v r="$rw" '$1==b && $2==r {printf "%s ", $7}' \
            "${RESULTS_DIR}/kata_results.csv")
        kata_iops_mean=$(compute_stats "$kata_iops_vals" | awk '{printf "%.0f", $1}')

        docker_iops_vals=$(awk -F',' -v b="$bs" -v r="$rw" '$1==b && $2==r {printf "%s ", $7}' \
            "${RESULTS_DIR}/docker_results.csv")
        docker_iops_mean=$(compute_stats "$docker_iops_vals" | awk '{printf "%.0f", $1}')

        delta=$(awk -v k="$kata_iops_mean" -v d="$docker_iops_mean" \
            'BEGIN { if (d > 0) printf "%.1f", (k-d)/d*100; else print "N/A" }')

        printf "| %-10s | %7s | %6s | %5s |\n" "$bs" "$kata_iops_mean" "$docker_iops_mean" "$delta"
    done

    echo ""
    echo "---"
    echo ""
done

# VM-Exit analysis (Kata+FC only)
echo "## VM-Exit Analysis (Kata+FC)"
echo ""
echo "Total VM exits captured per fio test during the Kata+FC phase."
echo ""
echo "| Block Size | I/O Type | Mean Exits | StdDev | CV |"
echo "|------------|----------|-----------|--------|-----|"

for bs in "${BLOCK_SIZES[@]}"; do
    for rw in "${IO_TYPES[@]}"; do
        exit_vals=$(awk -F',' -v b="$bs" -v r="$rw" '$1==b && $2==r {printf "%s ", $10}' \
            "${RESULTS_DIR}/kata_results.csv")
        if [[ -n "$exit_vals" ]]; then
            exit_stats=$(compute_stats "$exit_vals")
            exit_mean=$(echo "$exit_stats" | awk '{printf "%.0f", $1}')
            exit_std=$(echo "$exit_stats" | awk '{printf "%.0f", $2}')
            exit_cv=$(echo "$exit_stats" | awk '{printf "%.1f%%", $3}')
            printf "| %-10s | %-8s | %9s | %6s | %5s |\n" \
                "$bs" "$rw" "$exit_mean" "$exit_std" "$exit_cv"
        fi
    done
done

echo ""
echo "### Exits per I/O Type (averaged across block sizes)"
echo ""
echo "| I/O Type | Mean Total Exits | Interpretation |"
echo "|----------|-----------------|----------------|"

for rw in "${IO_TYPES[@]}"; do
    all_exit_vals=$(awk -F',' -v r="$rw" '$2==r {printf "%s ", $10}' \
        "${RESULTS_DIR}/kata_results.csv")
    if [[ -n "$all_exit_vals" ]]; then
        avg_exits=$(compute_stats "$all_exit_vals" | awk '{printf "%.0f", $1}')
        case "$rw" in
            read)      interp="Block device read via virtio-mmio" ;;
            write)     interp="Block write + fsync via virtio-mmio" ;;
            randread)  interp="Random seek + read emulation" ;;
            randwrite) interp="Random write + journal overhead" ;;
        esac
        printf "| %-10s | %15s | %s |\n" "$rw" "$avg_exits" "$interp"
    fi
done

echo ""
echo "---"
echo ""

# Per-run raw data table
echo "## Per-Run Raw Data"
echo ""
echo "### Kata+FC (devmapper)"
echo ""
echo '```'
column -t -s',' "${RESULTS_DIR}/kata_results.csv"
echo '```'
echo ""
echo "### Docker (disk volume)"
echo ""
echo '```'
column -t -s',' "${RESULTS_DIR}/docker_results.csv"
echo '```'
echo ""
echo "_Raw fio JSON output for each run saved in \`${RESULTS_DIR}/\`._"

} > "$REPORT"

log "Report saved: $REPORT"
log "Done! Total tests: $((${#BLOCK_SIZES[@]} * ${#IO_TYPES[@]} * RUNS * 2))"
log "View with: cat $REPORT"
