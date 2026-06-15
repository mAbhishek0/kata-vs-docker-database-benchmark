#!/bin/bash
# Cleanup script - removes downloaded files and images only (keeps setup intact)
set -e

echo "=== Cleaning up downloaded artifacts ==="

echo "[1/5] Removing mysql-fc container..."
sudo ctr tasks kill -s SIGKILL mysql-fc 2>/dev/null || true
sudo ctr containers delete mysql-fc 2>/dev/null || true
sudo ctr snapshots --snapshotter devmapper rm mysql-fc 2>/dev/null || true

echo "[2/5] Removing ctr images..."
sudo ctr images rm docker.io/library/alpine:latest 2>/dev/null || true
sudo ctr images rm docker.io/library/mysql-bench:local 2>/dev/null || true

echo "[3/5] Removing Docker image..."
docker rmi mysql-bench:local 2>/dev/null || true

echo "[4/5] Removing /tmp build artifacts..."
rm -rf /tmp/custom-build
rm -f /tmp/mysql-bench.tar

echo "[5/5] Removing downloaded files..."
rm -f kata-static.tar.zst
rm -f firecracker jailer

echo "Done. Setup (Kata, Firecracker, devmapper) is untouched."
