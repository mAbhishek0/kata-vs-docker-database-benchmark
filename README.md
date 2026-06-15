# Kata Containers vs Docker: Database Performance Benchmarks

This repository contains the benchmarking scripts, raw experimental results, and the final report for a comparative performance study between Kata Containers (using Firecracker microVMs) and standard Docker containers. The primary focus is on evaluating the performance overhead of hardware-level isolation for database workloads.

## Overview

The study evaluates the trade-offs of using microVMs for strong container isolation. It specifically looks at:

* **Disk I/O Performance:** Comparing `devmapper` ( Kata) against native host disk volumes (Docker) using `fio`.
* **OLTP Database Performance:** Running MySQL workloads using `sysbench` to measure transaction rates, query throughput, and latency.
* **Virtualization Overhead:** Tracking VM-exit rates during database operations to quantify the exact cost of the Firecracker hypervisor layer.
* **Resource Isolation:** Measuring how noisy neighbor workloads impact database latency under load.

## Project Structure

* `scripts/`: Bash and Python scripts used to run the experiments and generate graphs.
  * `benchmarks/`: The core benchmarking scripts for disk I/O, OLTP, and isolation tests.
  * `plots/`: Python scripts to parse the raw data and generate the charts used in the report.
* `results/`: The raw data, `sysbench` outputs, `fio` logs, and parsed CSVs from all test runs.
* `paper/`: The LaTeX source code for the final SSP end-term report.
* `docs/`: Additional project documentation and environment setup guides.

## Initial Setup

Before running the benchmarking scripts, ensure your host environment meets the following requirements:

1. **Container Runtimes:**
   - Docker installed and running natively.
   - Kata Containers installed with the `kata-runtime` and `firecracker` hypervisor available in your PATH.
   - `containerd` installed with the `ctr` CLI available.

2. **Storage Configuration (Crucial):**
   - Kata Containers requires block-device backing for optimal performance. You must have the `devmapper` snapshotter configured in containerd.
   - A devmapper thin pool named `devpool` must be active (verify with `sudo dmsetup ls`).

3. **System Dependencies:**
   - The scripts rely on various system profiling tools. Install them via your package manager:
     - `sysstat` (provides `mpstat`, `iostat`)
     - `linux-perf` (provides `perf` for VM-exit tracking)
     - `python3`, `python3-pandas`, `python3-matplotlib` (for generating plots)

## Running the Scripts

The benchmark suite is located in the `scripts/benchmarks/` directory. Due to their nature, they must be executed with root privileges (`sudo`) to isolate CPU cores, drop caches, and read hardware performance counters.

**1. Run Benchmarks:**
Execute the desired benchmark script. Each script creates a timestamped results directory (e.g., `bench_diskio_YYYYMMDD_HHMMSS`) containing raw JSON/CSV data and a markdown summary report.

* **`benchmark_disk_io.sh`**: Runs `fio` to compare raw disk I/O performance between Docker native volumes and Kata+FC devmapper block devices.
* **`benchmark_oltp.sh`**: Runs the `sysbench` OLTP workload on a MySQL database inside a Kata+Firecracker microVM, while profiling KVM VM-exits.
* **`benchmark_oltp_docker.sh`**: The native Docker baseline. Runs the `sysbench` workload on a host disk volume.
* **`benchmark_oltp_docker_tmpfs.sh`**: Runs the `sysbench` workload on native Docker using a `tmpfs` RAM disk to eliminate disk I/O bottlenecks.
* **`benchmark_isolation_test.sh`**: Investigates Docker performance variance by sequentially applying and reverting host tunings (THP, NUMA balancing, CPU isolation).

```bash
sudo ./scripts/benchmarks/benchmark_disk_io.sh
sudo ./scripts/benchmarks/benchmark_oltp.sh
sudo ./scripts/benchmarks/benchmark_oltp_docker.sh
sudo ./scripts/benchmarks/benchmark_oltp_docker_tmpfs.sh
sudo ./scripts/benchmarks/benchmark_isolation_test.sh
```

**2. Generate Plots:**
Once the benchmarks complete, you can generate the graphs used in the report by running the Python plotting scripts. These scripts automatically read the most recent data from the `results/` directory and save the PNG graphs into `paper/figures/`.

```bash
python3 ./scripts/plots/generate_diskio_plots.py
python3 ./scripts/plots/generate_mysql_plots.py
```

**3. Cleanup:**
To clean up lingering containers, custom images, and temporary files without affecting your system configuration:

```bash
sudo ./scripts/cleanup.sh
```
