# Kata + FC Installation Guide

Created: April 7, 2026 6:36 PM

# The Definitive Guide: Kata Containers (v3.x) + Firecracker on Ubuntu

## Step 1: Install Dependencies and Firecracker

Firecracker is the ultra-lightweight Virtual Machine Monitor (VMM) that provides hardware isolation without the bloat of QEMU.

```jsx
# 1. Install necessary extraction and web tools
sudo apt-get update && sudo apt-get install -y zstd curl wget

# 2. Download Firecracker and Jailer (v1.15.0)
FC_VERSION="v1.15.0"
curl -Lo firecracker "https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-x86_64"
curl -Lo jailer "https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/jailer-${FC_VERSION}-x86_64"

# 3. Make executable and move to system PATH
sudo chmod +x firecracker jailer
sudo mv firecracker /usr/local/bin/
sudo mv jailer /usr/local/bin/
```

**Why we did this:** Firecracker needs to be in your `$PATH` so the Kata runtime can invoke it. `zstd` is required because modern Kata releases use Zstandard compression instead of `.xz`.

## Step 2: Install Modern Kata Containers

Kata Containers acts as the OCI-compliant translation layer between `containerd` and the Firecracker hypervisor.

```jsx
# 1. Download the Kata 3.28.0 static release
wget -q --show-progress -O kata-static.tar.zst "https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-amd64.tar.zst"

# 2. Extract to the root directory (places files in /opt/kata)
sudo tar -I zstd -xf kata-static.tar.zst -C /

# 3. Symlink the universal shim and runtime to the system PATH
sudo ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2
sudo ln -sf /opt/kata/bin/kata-runtime /usr/local/bin/kata-runtime
```

**Why we did this:** Older tutorials tell you to look for a specific `containerd-shim-kata-fc-v2` binary. **That binary is dead.** Modern Kata consolidates everything into a single, universal shim (`containerd-shim-kata-v2`). The hypervisor (QEMU vs. Firecracker) is now selected entirely via configuration files, not separate binaries.

## Step 3: Configure Devmapper Storage

Firecracker cannot boot from Docker/Containerd's default `overlayfs` storage driver. It requires a raw block device. We use Linux `devmapper` to create a thin-provisioned storage pool.

```jsx
sudo tee /usr/local/bin/setup-devmapper.sh > /dev/null << 'EOF'
#!/bin/bash
set -ex
DATA_DIR=/var/lib/containerd/devmapper
POOL_NAME=devpool

mkdir -p ${DATA_DIR}
sudo touch "${DATA_DIR}/data"
sudo truncate -s 50G "${DATA_DIR}/data"  # Sparse file (doesn't use 50G immediately)
sudo touch "${DATA_DIR}/meta"
sudo truncate -s 5G "${DATA_DIR}/meta"

DATA_DEV=$(sudo losetup --find --show "${DATA_DIR}/data")
META_DEV=$(sudo losetup --find --show "${DATA_DIR}/meta")
SECTOR_SIZE=512
DATA_SIZE="$(sudo blockdev --getsize64 -q ${DATA_DEV})"
LENGTH_IN_SECTORS=$(bc <<< "${DATA_SIZE}/${SECTOR_SIZE}")
DATA_BLOCK_SIZE=128
LOW_WATER_MARK=32768

sudo dmsetup create "${POOL_NAME}" \
    --table "0 ${LENGTH_IN_SECTORS} thin-pool ${META_DEV} ${DATA_DEV} ${DATA_BLOCK_SIZE} ${LOW_WATER_MARK}"
EOF

sudo chmod +x /usr/local/bin/setup-devmapper.sh
sudo /usr/local/bin/setup-devmapper.sh
```

**Why we did this:** This creates a 50GB virtual ceiling for storage, but limits each individual container sandbox to a 4GB slice. It gives Firecracker the physical block architecture it expects without immediately filling up your hard drive.

## Step 4: Configure Containerd

We must tell `containerd` about our new devmapper pool and register the Kata runtime.

```jsx
# 1. Ensure the directory exists and generate a clean default config
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
```

### 2. Manually Edit the Config File:

Open the file: `sudo nano /etc/containerd/config.toml`

#### A. Find the `devmapper` section and update it to look like this:

```jsx
[plugins."io.containerd.snapshotter.v1.devmapper"]
    async_remove = false
    base_image_size = "4GB"
    discard_blocks = true
    fs_options = ""
    fs_type = ""
    pool_name = "devpool"
    root_path = "/var/lib/containerd/devmapper"
```

#### B. Find the `runtimes` section and add Kata exactly as a sibling to `runc`:

```jsx
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes]

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          ... (leave runc settings alone) ...

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
          runtime_type = "io.containerd.kata.v2"
```

```jsx
# 3. Restart Containerd
sudo systemctl restart containerd
```

**Why we did this:** TOML file nesting is extremely strict. By placing `kata` exactly parallel to `runc`, `containerd` recognizes it as a valid alternative runtime. We use `io.containerd.kata.v2` to route traffic to the universal shim we linked in Step 2.

## Step 5: The `ctr` Bypass Fix (Forcing Firecracker)

Low-level tools like `ctr` bypass standard Kubernetes/CRI configurations. To guarantee Kata uses Firecracker (and doesn't silently fall back to QEMU), we hardwire the Kata default configuration at the filesystem level.

```jsx
# 1. Force Kata's default config to be the Firecracker config
sudo ln -sf /opt/kata/share/defaults/kata-containers/configuration-fc.toml /opt/kata/share/defaults/kata-containers/configuration.toml

# 2. Ensure Kata can find the Firecracker binaries
sudo ln -sf /usr/local/bin/firecracker /opt/kata/bin/firecracker
sudo ln -sf /usr/local/bin/jailer /opt/kata/bin/jailer
```

**Why we did this:** This was the final hurdle. By replacing `configuration.toml` (which defaults to QEMU) with `configuration-fc.toml`, it becomes impossible for Kata to launch QEMU, regardless of what tool you use to start the container. Furthermore, Kata's config files strictly look for hypervisor binaries inside `/opt/kata/bin/`, so we symlinked your system binaries there to satisfy it.

## Step 6: Verification

Prove that the system works by launching a container and verifying the hardware architecture from the inside.

```jsx
# 1. Pull a test image using the devmapper storage
sudo ctr images pull --snapshotter devmapper docker.io/library/alpine:latest

# 2. Run the container, checking the boot logs (dmesg) for Virtio-MMIO
sudo ctr run --rm --snapshotter devmapper --runtime io.containerd.kata.v2 docker.io/library/alpine:latest hw-test dmesg | grep -i virtio_mmio
```

**Expected Result:** You should see multiple lines registering `virtio_mmio` devices (e.g., `virtio-mmio: Registering device...`). This guarantees the container is running inside a Firecracker microVM, as QEMU would register `virtio-pci` devices instead.

## Step 7: Running a Container

### 1. Build and Import the Image (Bypassing the Network Gap)

By default, microVMs launched via `ctr` are completely air-gapped (no internet access). If your application requires extra packages, do not try to `apt-get install` them inside the running VM. Instead, build a custom image using Docker, then side-load it into `containerd`.

```jsx
# A. Build the image in an isolated directory using Docker (which has internet)
mkdir -p /tmp/custom-build && cd /tmp/custom-build
cat << 'EOF' > Dockerfile
FROM docker.io/library/mysql:8.0-debian
RUN apt-get update -qq && apt-get install -y sysbench procps
EOF
docker build -t mysql-bench:local .
cd - > /dev/null

# B. Save the image and import it into containerd's devmapper pool
docker save mysql-bench:local > /tmp/mysql-bench.tar
sudo ctr images import --snapshotter devmapper /tmp/mysql-bench.tar
```

**Why we did this:** `ctr` and Docker maintain completely separate image caches. `ctr` cannot see images pulled by Docker. Furthermore, `ctr` needs the image explicitly unpacked into the `devmapper` storage pool so Firecracker can mount it as a virtual hard drive.

### 2. Launch the MicroVM (The Storage Architecture)

Launch the container using the imported image and the `devmapper` snapshotter.

```jsx
sudo ctr run -d \
  --snapshotter devmapper \
  --runtime io.containerd.kata.v2 \
  --env MYSQL_ROOT_PASSWORD=password \
  docker.io/library/mysql-bench:local mysql-fc
```

**Why we did this:** Notice the deliberate absence of a host bind-mount (e.g., no `--mount type=bind,src=/tmp/data...`). Host folder sharing uses a protocol called `virtio-fs`. Heavy database engines like InnoDB rely on low-level Linux block allocation calls (like `fallocate`) which `virtio-fs` often rejects, causing the database to crash with an "Error 1114: The table is full" message. By relying entirely on the `devmapper` snapshotter, we force Firecracker to use `virtio-mmio` raw block storage, bypassing the crash and unlocking bare-metal disk speeds.

### 3. Interacting with the Running VM

```jsx
# Check if the database is alive
sudo ctr tasks exec --exec-id ping1 -t mysql-fc mysqladmin ping -h 127.0.0.1 -uroot -ppassword

# Run a bash command inside the microVM
sudo ctr tasks exec --exec-id shell1 -t mysql-fc bash -c "free -m"
```

**Why we did this:** Every execution command via `ctr` requires a unique `--exec-id` (e.g., `ping1`, `shell1`). If you reuse an ID, `containerd` will throw an error because it strictly tracks every individual process spawned inside the sandbox. Also, forcing TCP connections (`-h 127.0.0.1`) avoids issues where the local Unix socket boots slower than the application expects.

### 4. Deep Cleanup (Avoiding Orphaned Snapshots)

```jsx
sudo ctr tasks kill -s SIGKILL mysql-fc 2>/dev/null
sudo ctr containers delete mysql-fc 2>/dev/null
sudo ctr snapshots --snapshotter devmapper rm mysql-fc 2>/dev/null
```

**Why we did this:** Deleting the container only removes the metadata. If you do not explicitly delete the `devmapper` snapshot, the 4GB virtual hard drive remains orphaned on your system. If you try to launch a new container with the same name, it will fatally crash with a `snapshot already exists` error.