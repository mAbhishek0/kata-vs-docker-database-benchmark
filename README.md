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

## Running the Benchmarks

The scripts in `scripts/benchmarks/` are designed to be run on a system configured with both Docker and Kata Containers (with Firecracker configured as the runtime). 

*(Note: Ensure your environment matches the setup described in the report before running these, as they require specific block device configurations like devmapper for Kata).*
