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
mkdir -p "${STAGING}"/{bin,sbin,usr/bin,usr/sbin,usr/lib,usr/share,lib,lib64,etc,proc,sys,dev,dev/pts,dev/shm,tmp,run,root,home/runner,mnt/checkpoint,host_tmp,mnt/usrlib,usr/share/dotnet,modules}

# 2. Install busybox utilities
echo "[1/7] Installing busybox utilities..."
if [ -f "${SCRIPT_DIR}/busybox" ]; then
    cp -a "${SCRIPT_DIR}/busybox" "${STAGING}/bin/busybox"
    chmod 755 "${STAGING}/bin/busybox"
else
    echo "Downloading static busybox..."
    curl -fsSL https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox -o "${STAGING}/bin/busybox"
    chmod 755 "${STAGING}/bin/busybox"
fi

# Create symlinks for busybox applets (EXCLUDING bash to prevent mmap size mismatch!)
BB_APPLETS=(
    sh mount umount mkdir rm cp mv ln ls ps cat echo grep egrep sed awk
    sleep sync date hostname uname ifconfig ip route insmod modprobe rmmod
    poweroff reboot tr find chmod chown test kill killall tail head vi readlink
)
for applet in "${BB_APPLETS[@]}"; do
    ln -sf /bin/busybox "${STAGING}/bin/${applet}"
    ln -sf /bin/busybox "${STAGING}/usr/bin/${applet}" 2>/dev/null || true
done

# CRITICAL: Copy native GNU bash and core utilities from host to ensure exact file size matching
echo "[2/7] Copying native GNU bash and core utilities from host..."
cp -a /bin/bash "${STAGING}/bin/bash"
chmod 755 "${STAGING}/bin/bash"
ln -sf /bin/bash "${STAGING}/usr/bin/bash"

HOST_CORE_BINS=(sleep cat hostname date mkdir uname tr touch sync git)
for b in "${HOST_CORE_BINS[@]}"; do
    for p in "/usr/bin/${b}" "/bin/${b}"; do
        if [ -f "${p}" ] && [ ! -L "${p}" ]; then
            rm -f "${STAGING}/bin/${b}" "${STAGING}/usr/bin/${b}"
            cp -a "${p}" "${STAGING}/bin/${b}"
            cp -a "${p}" "${STAGING}/usr/bin/${b}"
            break
        fi
    done
done

if [ -d /usr/lib/git-core ]; then
    mkdir -p "${STAGING}/usr/lib/git-core"
    cp -a /usr/lib/git-core/* "${STAGING}/usr/lib/git-core/" 2>/dev/null || true
fi

# 3. Install kernel modules for Linux 6.17.0-40-generic (bzImage)
echo "[3/7] Packaging guest kernel modules..."
if [ -d "${SCRIPT_DIR}/modules" ]; then
    cp -a "${SCRIPT_DIR}/modules"/* "${STAGING}/modules/"
    chmod 644 "${STAGING}/modules"/*
    echo "Installed $(ls -1 "${STAGING}/modules" | wc -l) modules to /modules/"
else
    echo "WARNING: ${SCRIPT_DIR}/modules not found!"
fi

# 4. Copy host CRIU binary and dynamic dependencies
echo "[4/7] Packaging CRIU binary and libraries..."
CRIU_BIN="$(which criu || echo "/usr/sbin/criu")"
if [ -f "${CRIU_BIN}" ]; then
    cp -a "${CRIU_BIN}" "${STAGING}/usr/sbin/criu"
    ln -sf /usr/sbin/criu "${STAGING}/bin/criu"
    chmod 755 "${STAGING}/usr/sbin/criu"

    mkdir -p "${STAGING}/lib/x86_64-linux-gnu" "${STAGING}/usr/lib/x86_64-linux-gnu" "${STAGING}/lib64"
    for bin_to_check in "${CRIU_BIN}" /bin/bash; do
        for lib in $(ldd "${bin_to_check}" 2>/dev/null | grep -o '/[^ ]*' || true); do
            if [ -f "${lib}" ]; then
                fname="$(basename "${lib}")"
                cp -a "${lib}" "${STAGING}/lib/x86_64-linux-gnu/${fname}" 2>/dev/null || true
                cp -a "${lib}" "${STAGING}/usr/lib/x86_64-linux-gnu/${fname}" 2>/dev/null || true
                if [[ "${lib}" == *ld-linux* ]]; then
                    cp -a "${lib}" "${STAGING}/lib64/${fname}" 2>/dev/null || true
                fi
            fi
        done
    done
fi

# Copy extra CoreCLR and system runtime libraries from host
EXTRA_LIBS=(
    "libstdc++.so.6"
    "libgcc_s.so.1"
    "libm.so.6"
    "libcrypto.so.3"
    "libssl.so.3"
    "libz.so.1"
    "libnuma.so.1"
    "liblttng-ust-common.so.1"
    "liblttng-ust.so.1"
    "liblttng-ust-tracepoint.so.1"
    "libicudata.so"
    "libicui18n.so"
    "libicuuc.so"
    "libtinfo.so.6"
    "libnss_dns.so"
    "libnss_files.so"
    "libnss_compat.so"
    "libnss_mdns4_minimal.so"
    "libresolv.so"
    "libselinux.so.1"
    "libpcre2-8.so.0"
)
for lib in "${EXTRA_LIBS[@]}"; do
    found_libs=$(find /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu -name "${lib}*" 2>/dev/null || true)
    for found_lib in ${found_libs}; do
        fname="$(basename "${found_lib}")"
        if [ -e "${found_lib}" ] && [ ! -e "${STAGING}/lib/x86_64-linux-gnu/${fname}" ]; then
            cp -a "${found_lib}" "${STAGING}/lib/x86_64-linux-gnu/${fname}" 2>/dev/null || true
            cp -a "${found_lib}" "${STAGING}/usr/lib/x86_64-linux-gnu/${fname}" 2>/dev/null || true
        fi
    done
done

# Ensure standard dynamic linker paths
if [ -f /lib64/ld-linux-x86-64.so.2 ]; then
    cp -a /lib64/ld-linux-x86-64.so.2 "${STAGING}/lib64/ld-linux-x86-64.so.2" 2>/dev/null || true
fi

# 5. Configure system files (SSL certs, ld cache, users, DNS, ICU timezone data)
echo "[5/7] Configuring system configuration files..."
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

# CRITICAL: Copy ICU zoneinfo files mapped by .NET 8 CoreCLR
if [ -d /usr/share/zoneinfo-icu ]; then
    echo "  -> Copying /usr/share/zoneinfo-icu files..."
    mkdir -p "${STAGING}/usr/share/zoneinfo-icu"
    cp -a /usr/share/zoneinfo-icu/* "${STAGING}/usr/share/zoneinfo-icu/" 2>/dev/null || true
fi
if [ -d /usr/share/zoneinfo ]; then
    echo "  -> Copying /usr/share/zoneinfo files..."
    mkdir -p "${STAGING}/usr/share/zoneinfo"
    cp -a /usr/share/zoneinfo/* "${STAGING}/usr/share/zoneinfo/" 2>/dev/null || true
fi

# Users and groups
cat << 'EOF' > "${STAGING}/etc/passwd"
root:x:0:0:root:/root:/bin/sh
runner:x:1001:1001:runner:/home/runner:/bin/bash
EOF
grep -E "^runner:" /etc/passwd >> "${STAGING}/etc/passwd" 2>/dev/null || true
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
echo "[6/7] Writing guest /init..."
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
if /bin/busybox ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up 2>/dev/null; then
    /bin/busybox route add default gw 10.0.2.2 dev eth0 2>/dev/null || true
    echo "[GUEST] eth0 configured: IP 10.0.2.15, Gateway 10.0.2.2"
else
    echo "[GUEST] WARNING: eth0 interface not found!"
fi

echo "=========================================================="
echo "=== QEMU Guest VM Booted for GitHub Runner Restore     ==="
echo "=== Hostname: $(/bin/busybox hostname)                 ==="
echo "=== Kernel:   $(/bin/busybox uname -r)                 ==="
echo "=== PID 1:    /bin/busybox sh /init                    ==="
echo "=========================================================="

# Mount 9p shares
/bin/busybox mkdir -p /mnt/checkpoint /home/runner /host_tmp /mnt/usrlib /usr/share/dotnet

echo "[GUEST] Mounting 9p shares..."
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose checkpoint /mnt/checkpoint 2>/dev/null && echo "[GUEST] Mounted checkpoint share" || echo "[GUEST] Warning: checkpoint mount"
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose host_runner /home/runner 2>/dev/null && echo "[GUEST] Mounted host_runner share" || echo "[GUEST] Warning: host_runner mount"
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose host_tmp /host_tmp 2>/dev/null && echo "[GUEST] Mounted host_tmp share" || echo "[GUEST] Warning: host_tmp mount"
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose usrlib /mnt/usrlib 2>/dev/null && echo "[GUEST] Mounted usrlib share" || echo "[GUEST] Warning: usrlib mount"
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose dotnet /usr/share/dotnet 2>/dev/null && echo "[GUEST] Mounted dotnet share" || echo "[GUEST] Warning: dotnet mount"

# Populate missing libraries from usrlib share
if [ -d /mnt/usrlib ]; then
    for f in /mnt/usrlib/*; do
        fname="$(/bin/busybox basename "$f")"
        if [ ! -e "/usr/lib/x86_64-linux-gnu/$fname" ]; then
            /bin/busybox ln -sf "$f" "/usr/lib/x86_64-linux-gnu/$fname" 2>/dev/null || true
        fi
        if [ ! -e "/lib/x86_64-linux-gnu/$fname" ]; then
            /bin/busybox ln -sf "$f" "/lib/x86_64-linux-gnu/$fname" 2>/dev/null || true
        fi
    done
fi

# Populate host /dev/shm
if [ -d /mnt/checkpoint/dev_shm ]; then
    echo "[GUEST] Restoring /dev/shm from host..."
    /bin/busybox cp -a /mnt/checkpoint/dev_shm/* /dev/shm/ 2>/dev/null || true
    /bin/busybox chmod 1777 /dev/shm
fi

# Populate host /tmp if needed (excluding any stale socket files)
if [ -d /mnt/checkpoint/host_tmp ]; then
    echo "[GUEST] Restoring /tmp from host..."
    /bin/busybox cp -a /mnt/checkpoint/host_tmp/* /tmp/ 2>/dev/null || true
fi

# Ensure diagnostic socket path is clean for CRIU bind
/bin/busybox rm -f /tmp/dotnet-diagnostic-*

# Copy checkpoint images to tmpfs for fast CRIU access
/bin/busybox mkdir -p /tmp/restore
echo "[GUEST] Copying checkpoint images to local tmpfs..."
/bin/busybox cp -a /mnt/checkpoint/* /tmp/restore/ 2>/dev/null || true
/bin/busybox chmod -R 777 /tmp/restore

# Create migration detection markers
/bin/busybox touch /tmp/migration_restored /dev/shm/migration_restored /mnt/checkpoint/migration_restored

# Notify ntfy that guest VM has booted
/bin/busybox wget -q -O - --post-data="GUEST VM BOOTED: hostname=$(/bin/busybox hostname) kernel=$(/bin/busybox uname -r)" http://ntfy.sh/runner-criu-debug-morsho-test 2>/dev/null || true

# Verify CRIU binary is runnable
echo "[GUEST] Testing CRIU binary..."
/usr/sbin/criu --version || echo "[GUEST] Warning: /usr/sbin/criu failed"

# Execute CRIU restore
echo "[GUEST] Executing CRIU restore command..."
set +e
/usr/sbin/criu restore -d -D /tmp/restore \
    --shell-job --file-locks --ext-unix-sk --skip-file-rwx-check --tcp-close \
    -v4 -o /mnt/checkpoint/restore_log.txt
RESTORE_RC=$?
set -e

echo "[GUEST] CRIU restore returned exit code: ${RESTORE_RC}"
/bin/busybox wget -q -O - --post-data="GUEST CRIU RESTORE RC=${RESTORE_RC}" http://ntfy.sh/runner-criu-debug-morsho-test 2>/dev/null || true

if [ ${RESTORE_RC} -ne 0 ]; then
    echo "[GUEST] [FAIL] CRIU restore failed! Showing last 60 lines of restore log:"
    /bin/busybox tail -n 60 /mnt/checkpoint/restore_log.txt 2>/dev/null || true
    /bin/busybox wget -q -O - --post-file=/mnt/checkpoint/restore_log.txt http://ntfy.sh/runner-criu-debug-morsho-test 2>/dev/null || true
    /bin/busybox sync
    /bin/busybox sleep 2
    /bin/busybox poweroff -f 2>/dev/null || true
    exit ${RESTORE_RC}
fi

echo "[GUEST] [OK] Process tree restored and running in VM!"
/bin/busybox wget -q -O - --post-data="GUEST PROCESS TREE RESTORED SUCCESSFULLY" http://ntfy.sh/runner-criu-debug-morsho-test 2>/dev/null || true
echo "[GUEST] Monitoring for Step 3 completion marker..."

STEP3_VERIFY="/mnt/checkpoint/step3_verification.txt"
POLL=0
MAX_POLL=60
FOUND=0

while [ ${POLL} -lt ${MAX_POLL} ]; do
    if [ -f "${STEP3_VERIFY}" ] && [ -s "${STEP3_VERIFY}" ]; then
        FOUND=1
        echo "[GUEST] Found Step 3 verification output after ${POLL}s!"
        break
    fi
    /bin/busybox sleep 1
    POLL=$((POLL + 1))
done

if [ ${FOUND} -eq 1 ]; then
    echo "=== [GUEST] Step 3 Verification Content ==="
    /bin/busybox cat "${STEP3_VERIFY}"
else
    echo "[GUEST] [WARNING] Step 3 verification file not generated or empty after ${MAX_POLL}s!"
fi

# Allow Runner.Worker and Runner.Listener to upload step logs and report completion
WORKER_PID=$(/bin/busybox grep "^WORKER_PID=" /mnt/checkpoint/state.txt 2>/dev/null | /bin/busybox cut -d= -f2 | /bin/busybox tr -d ' \n' || echo "")
echo "[GUEST] Monitoring Runner.Worker (PID ${WORKER_PID}) completion..."
WAIT_WORKER=0
while [ -n "${WORKER_PID}" ] && [ -d "/proc/${WORKER_PID}" ] && [ ${WAIT_WORKER} -lt 60 ]; do
    /bin/busybox sleep 1
    WAIT_WORKER=$((WAIT_WORKER + 1))
done
echo "[GUEST] Runner.Worker completed (${WAIT_WORKER}s elapsed)."

echo "[GUEST] Waiting 15 seconds for Runner.Listener to flush final reporting..."
/bin/busybox sleep 15

echo "=========================================================="
echo "=== VM CI Tasks Complete. Syncing and Powering off.    ==="
echo "=========================================================="
/bin/busybox sync
/bin/busybox sleep 2
/bin/busybox poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger 2>/dev/null || true
/bin/busybox reboot -f 2>/dev/null || true
EOF
chmod 755 "${STAGING}/init"

# 7. Package initramfs
echo "[7/7] Packing initramfs.cpio.gz..."
(
    cd "${STAGING}"
    find . -mindepth 1 | cpio -H newc -o 2>/dev/null | gzip -1 > "${INITRAMFS_OUT}"
)

INITRAMFS_SIZE=$(du -h "${INITRAMFS_OUT}" | awk '{print $1}')
echo "=== Assembly Complete: ${INITRAMFS_OUT} (${INITRAMFS_SIZE}) ==="
exit 0
