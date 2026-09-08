#!/usr/bin/env bash
set -euo pipefail

# appliance/assemble_initramfs.sh
# Runs ON the runner to assemble the QEMU microVM initramfs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STAGING="${SCRIPT_DIR}/staging"
INITRAMFS_OUT="${SCRIPT_DIR}/initramfs.cpio.gz"

echo "=== Assembling QEMU MicroVM Restore Initramfs ==="
echo "Target output: ${INITRAMFS_OUT}"

rm -rf "${STAGING}"
mkdir -p "${STAGING}"

# 1. Base directory layout
mkdir -p "${STAGING}"/{bin,sbin,usr/bin,usr/sbin,usr/lib,usr/share,lib,lib64,etc,proc,sys,dev,dev/pts,dev/shm,tmp,run,root,home/runner,mnt/checkpoint,host_tmp,modules}

# 2. Install busybox and standard symlinks
echo "[1/6] Installing busybox utilities..."
if [ -f "${SCRIPT_DIR}/busybox" ]; then
    cp -a "${SCRIPT_DIR}/busybox" "${STAGING}/bin/busybox"
    chmod 755 "${STAGING}/bin/busybox"
else
    echo "Downloading static busybox..."
    curl -fsSL https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox -o "${STAGING}/bin/busybox"
    chmod 755 "${STAGING}/bin/busybox"
fi

# Create symlinks for common busybox applets
BB_APPLETS=(
    sh bash mount umount mkdir rm cp mv ln ls ps cat echo grep egrep sed awk
    sleep sync date hostname uname ifconfig ip route insmod modprobe rmmod
    poweroff reboot tr find chmod chown test kill killall tail head vi readlink
)
for applet in "${BB_APPLETS[@]}"; do
    ln -sf /bin/busybox "${STAGING}/bin/${applet}"
    ln -sf /bin/busybox "${STAGING}/usr/bin/${applet}" 2>/dev/null || true
done

# 3. Install kernel modules for Linux 6.17.0-40-generic (bzImage)
echo "[2/6] Packaging guest kernel modules..."
if [ -d "${SCRIPT_DIR}/modules" ]; then
    cp -a "${SCRIPT_DIR}/modules"/* "${STAGING}/modules/"
    chmod 644 "${STAGING}/modules"/*
    echo "Installed $(ls -1 "${STAGING}/modules" | wc -l) modules to /modules/"
else
    echo "WARNING: ${SCRIPT_DIR}/modules not found!"
fi

# 4. Copy host CRIU binary and dynamic dependencies
echo "[3/6] Packaging CRIU binary and libraries..."
CRIU_BIN="$(which criu || echo "/usr/sbin/criu")"
if [ -f "${CRIU_BIN}" ]; then
    cp -a "${CRIU_BIN}" "${STAGING}/usr/sbin/criu"
    ln -sf /usr/sbin/criu "${STAGING}/bin/criu"
    chmod 755 "${STAGING}/usr/sbin/criu"

    # Copy shared libraries required by CRIU
    mkdir -p "${STAGING}/lib/x86_64-linux-gnu" "${STAGING}/usr/lib/x86_64-linux-gnu"
    for lib in $(ldd "${CRIU_BIN}" 2>/dev/null | grep -o '/[^ ]*' || true); do
        if [ -f "${lib}" ]; then
            fname="$(basename "${lib}")"
            cp -a "${lib}" "${STAGING}/lib/x86_64-linux-gnu/${fname}" 2>/dev/null || true
            cp -a "${lib}" "${STAGING}/usr/lib/x86_64-linux-gnu/${fname}" 2>/dev/null || true
            if [[ "${lib}" == *ld-linux* ]]; then
                mkdir -p "${STAGING}/lib64"
                cp -a "${lib}" "${STAGING}/lib64/${fname}" 2>/dev/null || true
            fi
        fi
    done
else
    echo "ERROR: criu binary not found!"
    exit 1
fi

# 5. Configure system files (SSL certs, ld cache, users, DNS)
echo "[4/6] Configuring system configuration files..."
if [ -f /etc/ld.so.cache ]; then
    cp -a /etc/ld.so.cache "${STAGING}/etc/ld.so.cache"
fi
if [ -d /etc/ld.so.conf.d ]; then
    mkdir -p "${STAGING}/etc/ld.so.conf.d"
    cp -a /etc/ld.so.conf.d/* "${STAGING}/etc/ld.so.conf.d/" 2>/dev/null || true
fi
if [ -f /etc/ld.so.conf ]; then
    cp -a /etc/ld.so.conf "${STAGING}/etc/ld.so.conf"
fi

# SSL certificates
mkdir -p "${STAGING}/etc/ssl" "${STAGING}/usr/lib/ssl"
if [ -d /etc/ssl/certs ]; then
    cp -a /etc/ssl/certs "${STAGING}/etc/ssl/"
    ln -sf /etc/ssl/certs "${STAGING}/usr/lib/ssl/certs"
    ln -sf /etc/ssl/certs/ca-certificates.crt "${STAGING}/usr/lib/ssl/cert.pem" 2>/dev/null || true
fi

# Locale archive
if [ -f /usr/lib/locale/locale-archive ]; then
    mkdir -p "${STAGING}/usr/lib/locale"
    cp -a /usr/lib/locale/locale-archive "${STAGING}/usr/lib/locale/locale-archive"
fi
if [ -d /usr/lib/x86_64-linux-gnu/gconv ]; then
    mkdir -p "${STAGING}/usr/lib/x86_64-linux-gnu/gconv"
    cp -a /usr/lib/x86_64-linux-gnu/gconv/* "${STAGING}/usr/lib/x86_64-linux-gnu/gconv/" 2>/dev/null || true
fi

# Users and groups
cat << 'EOF' > "${STAGING}/etc/passwd"
root:x:0:0:root:/root:/bin/sh
runner:x:1001:1001:runner:/home/runner:/bin/bash
EOF
# Match host runner user if exists
grep -E "^runner:" /etc/passwd >> "${STAGING}/etc/passwd" 2>/dev/null || true
# Match host current user if different
grep -E "^$(whoami):" /etc/passwd >> "${STAGING}/etc/passwd" 2>/dev/null || true

cat << 'EOF' > "${STAGING}/etc/group"
root:x:0:
runner:x:1001:
EOF
grep -E "^runner:" /etc/group >> "${STAGING}/etc/group" 2>/dev/null || true

cat << 'EOF' > "${STAGING}/etc/hosts"
127.0.0.1   localhost
::1         localhost ip6-localhost ip6-loopback
EOF

cat << 'EOF' > "${STAGING}/etc/resolv.conf"
nameserver 10.0.2.3
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

cat << 'EOF' > "${STAGING}/etc/nsswitch.conf"
passwd:         files
group:          files
hosts:          files dns
networks:       files
protocols:      files
services:       files
ethers:         files
rpc:            files
EOF

# 6. Generate guest /init
echo "[5/6] Writing guest /init..."
cat << 'EOF' > "${STAGING}/init"
#!/bin/busybox sh
set -e

# Mount pseudo-filesystems
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox mkdir -p /dev/pts /dev/shm
/bin/busybox mount -t devpts devpts /dev/pts 2>/dev/null || true
/bin/busybox mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true
/bin/busybox mount -t tmpfs tmpfs /tmp 2>/dev/null || true
/bin/busybox chmod 1777 /tmp /dev/shm

# Set VM hostname
/bin/busybox hostname qemu-restore-vm

# Set max pid limit
echo 4194304 > /proc/sys/kernel/pid_max 2>/dev/null || true

# Load diagnostic kernel modules
for mod in unix_diag af_packet_diag netlink_diag inet_diag tcp_diag veth; do
    if [ -f "/modules/${mod}.ko" ]; then
        /bin/busybox insmod "/modules/${mod}.ko" 2>/dev/null || true
    fi
done

# Load 9p virtio filesystem modules in dependency order
for mod in netfs 9pnet 9pnet_virtio 9p; do
    if [ -f "/modules/${mod}.ko" ]; then
        /bin/busybox insmod "/modules/${mod}.ko" 2>/dev/null || true
    fi
done

# Configure networking (QEMU user-mode NAT network)
/bin/busybox ifconfig lo up 2>/dev/null || true
/bin/busybox ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up 2>/dev/null || true
/bin/busybox route add default gw 10.0.2.2 dev eth0 2>/dev/null || true

echo "=========================================================="
echo "=== QEMU Guest VM Booted for GitHub Runner Restore     ==="
echo "=== Hostname: $(/bin/busybox hostname)                 ==="
echo "=== Kernel:   $(/bin/busybox uname -r)                 ==="
echo "=== PID 1:    /bin/busybox sh /init                    ==="
echo "=========================================================="

# Mount 9p shares
/bin/busybox mkdir -p /mnt/checkpoint /home/runner /usr /lib /host_tmp /etc/ssl

echo "[GUEST] Mounting 9p shares..."
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose checkpoint /mnt/checkpoint 2>/dev/null || echo "[GUEST] Warning: checkpoint mount"
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose host_runner /home/runner 2>/dev/null || echo "[GUEST] Warning: host_runner mount"
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose host_tmp /host_tmp 2>/dev/null || echo "[GUEST] Warning: host_tmp mount"
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose host_ssl /etc/ssl 2>/dev/null || echo "[GUEST] Warning: host_ssl mount"
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose host_usr /usr 2>/dev/null || echo "[GUEST] Warning: host_usr mount"
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose host_lib /lib 2>/dev/null || echo "[GUEST] Warning: host_lib mount"

# Populate host /dev/shm
if [ -d /mnt/checkpoint/dev_shm ]; then
    echo "[GUEST] Restoring /dev/shm from host..."
    /bin/busybox cp -a /mnt/checkpoint/dev_shm/* /dev/shm/ 2>/dev/null || true
    /bin/busybox chmod 1777 /dev/shm
fi

# Populate host /tmp if needed
if [ -d /mnt/checkpoint/host_tmp ]; then
    echo "[GUEST] Restoring /tmp from host..."
    /bin/busybox cp -a /mnt/checkpoint/host_tmp/* /tmp/ 2>/dev/null || true
fi

# Copy checkpoint images to tmpfs for fast CRIU access
/bin/busybox mkdir -p /tmp/restore
echo "[GUEST] Copying checkpoint images to local tmpfs..."
/bin/busybox cp -a /mnt/checkpoint/* /tmp/restore/ 2>/dev/null || true
/bin/busybox chmod -R 777 /tmp/restore

# Create migration detection markers
/bin/busybox touch /tmp/migration_restored /dev/shm/migration_restored /mnt/checkpoint/migration_restored

# Execute CRIU restore
echo "[GUEST] Executing CRIU restore command..."
set +e
criu restore -d -D /tmp/restore \
    --shell-job --file-locks --ext-unix-sk --skip-file-rwx-check --tcp-close \
    -v4 -o /mnt/checkpoint/restore_log.txt
RESTORE_RC=$?
set -e

echo "[GUEST] CRIU restore returned exit code: ${RESTORE_RC}"

if [ ${RESTORE_RC} -ne 0 ]; then
    echo "[GUEST] [FAIL] CRIU restore failed! Showing last 50 lines of log:"
    /bin/busybox tail -n 50 /mnt/checkpoint/restore_log.txt 2>/dev/null || true
    /bin/busybox sync
    /bin/busybox sleep 2
    /bin/busybox poweroff -f 2>/dev/null || true
    exit ${RESTORE_RC}
fi

echo "[GUEST] [OK] Process tree restored and running in VM!"
echo "[GUEST] Monitoring for job completion..."

# Wait for Runner.Worker and Runner.Listener to finish steps
WAIT_SECS=0
MAX_SECS=120
while [ ${WAIT_SECS} -lt ${MAX_SECS} ]; do
    if ! /bin/busybox ps | /bin/busybox grep -E "Runner\.Worker" >/dev/null 2>&1; then
        echo "[GUEST] Runner.Worker has completed (${WAIT_SECS}s elapsed)."
        break
    fi
    /bin/busybox sleep 1
    WAIT_SECS=$((WAIT_SECS + 1))
done

echo "[GUEST] Allowing 12 seconds for Runner.Listener to finish final reporting..."
/bin/busybox sleep 12

echo "=========================================================="
echo "=== VM CI Tasks Complete. Syncing and Powering off.    ==="
echo "=========================================================="
/bin/busybox sync
/bin/busybox sleep 1
/bin/busybox poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger 2>/dev/null || true
/bin/busybox reboot -f 2>/dev/null || true
EOF
chmod 755 "${STAGING}/init"

# 7. Package initramfs
echo "[6/6] Packing initramfs.cpio.gz..."
(
    cd "${STAGING}"
    find . -mindepth 1 | cpio -H newc -o 2>/dev/null | gzip -1 > "${INITRAMFS_OUT}"
)

INITRAMFS_SIZE=$(du -h "${INITRAMFS_OUT}" | awk '{print $1}')
echo "=== Assembly Complete: ${INITRAMFS_OUT} (${INITRAMFS_SIZE}) ==="
exit 0
