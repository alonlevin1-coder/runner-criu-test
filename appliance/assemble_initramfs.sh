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
mkdir -p "${STAGING}"/{bin,sbin,usr/bin,usr/sbin,usr/lib,usr/lib64,usr/lib/x86_64-linux-gnu,usr/share,etc,proc,sys,dev,dev/pts,dev/shm,tmp,run,root,home/runner,mnt/checkpoint,host_tmp,mnt/usrlib,host_usr,host_bin,host_lib,host_lib64,host_opt,opt,usr/share/dotnet,modules}
ln -sf usr/lib "${STAGING}/lib"
ln -sf usr/lib64 "${STAGING}/lib64"

copy_lib() {
    local src="$1"
    local dest_dir="${STAGING}/usr/lib/x86_64-linux-gnu"
    [ -e "${src}" ] || return 0
    if [ -L "${src}" ]; then
        local target
        target="$(readlink "${src}")"
        local sname
        sname="$(basename "${src}")"
        ln -sf "${target}" "${dest_dir}/${sname}" 2>/dev/null || true
        local real
        real="$(realpath "${src}")"
        if [ -f "${real}" ]; then
            local rname
            rname="$(basename "${real}")"
            if [ ! -f "${dest_dir}/${rname}" ]; then
                cp -a "${real}" "${dest_dir}/${rname}" 2>/dev/null || true
            fi
        fi
    else
        local fname
        fname="$(basename "${src}")"
        if [ ! -f "${dest_dir}/${fname}" ]; then
            cp -a "${src}" "${dest_dir}/${fname}" 2>/dev/null || true
        fi
    fi
}


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
    pivot_root switch_root
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

# Pack a few core utils into initramfs for early boot only. Full host /usr and /bin
# are exposed via 9p at restore time (see t9_restore.sh) — cheaper than copying
# every binary and .so into the initramfs on each workflow run.
HOST_CORE_BINS=(sleep cat hostname date mkdir uname tr touch sync git tee)
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

# Setuid sudo shim to support root commands (e.g. apt-get) in guest microVM
echo "Compiling setuid sudo shim..."
mkdir -p "${STAGING}/usr/local/bin" "${STAGING}/bin"
cat << 'CEOF' > /tmp/sudo_shim.c
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char *argv[]) {
    if (setgid(0) != 0) perror("setgid");
    if (setuid(0) != 0) perror("setuid");

    int i = 1;
    while (i < argc) {
        if (strcmp(argv[i], "--") == 0) {
            i++;
            break;
        }
        if (argv[i][0] == '-') {
            if (strcmp(argv[i], "-u") == 0 || strcmp(argv[i], "-g") == 0 || strcmp(argv[i], "-D") == 0) {
                i += 2;
                continue;
            }
            i++;
            continue;
        }
        break;
    }

    if (i >= argc) {
        return 0;
    }

    execvp(argv[i], &argv[i]);
    perror("sudo execvp failed");
    return 127;
}
CEOF
gcc -O2 /tmp/sudo_shim.c -o "${STAGING}/opt_sudo_shim"
chmod 4755 "${STAGING}/opt_sudo_shim"
cp -a "${STAGING}/opt_sudo_shim" "${STAGING}/usr/local/bin/sudo"
chmod 4755 "${STAGING}/usr/local/bin/sudo"
cp -a "${STAGING}/opt_sudo_shim" "${STAGING}/bin/sudo"
chmod 4755 "${STAGING}/bin/sudo"
rm -f /tmp/sudo_shim.c



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
CRIU_BIN="${REPO_DIR}/bin/criu"
[ -x "${CRIU_BIN}" ] || CRIU_BIN="$(which criu 2>/dev/null || echo "/usr/sbin/criu")"
if [ -f "${CRIU_BIN}" ]; then
    cp -a "${CRIU_BIN}" "${STAGING}/usr/sbin/criu"
    cp -a "${CRIU_BIN}" "${STAGING}/sbin/criu"
    ln -sf /sbin/criu "${STAGING}/bin/criu"
    chmod 755 "${STAGING}/usr/sbin/criu" "${STAGING}/sbin/criu"

    for bin_to_check in "${CRIU_BIN}" /bin/bash; do
        for lib in $(ldd "${bin_to_check}" 2>/dev/null | grep -o '/[^ ]*' || true); do
            copy_lib "${lib}"
        done
    done
fi

if [ -d "${REPO_DIR}/bin/lib" ]; then
    for blib in "${REPO_DIR}/bin/lib"/*; do
        copy_lib "${blib}"
    done
fi
# Package official Ubuntu run-init binary and its klibc shared runtime
if [ -f /usr/lib/klibc/bin/run-init ]; then
    rm -f "${STAGING}/sbin/run-init"
    cp -a /usr/lib/klibc/bin/run-init "${STAGING}/sbin/run-init"
    chmod 755 "${STAGING}/sbin/run-init"
    mkdir -p "${STAGING}/usr/lib" "${STAGING}/lib"
    cp -a /usr/lib/klibc-*.so "${STAGING}/usr/lib/" 2>/dev/null || true
    cp -a /lib/klibc-*.so "${STAGING}/lib/" 2>/dev/null || true
fi

# Stub iptables so CRIU post-restore netfilter cleanup does not fail with status 127
cat << 'IPT_EOF' > "${STAGING}/sbin/iptables"
#!/bin/sh
exit 0
IPT_EOF
chmod 755 "${STAGING}/sbin/iptables"
ln -sf /sbin/iptables "${STAGING}/usr/sbin/iptables" 2>/dev/null || true

# Dropbear for two-stage SSH (host helper runs criu restore after boot).
echo "[4b/7] Packaging dropbear..."
if ! command -v dropbear >/dev/null 2>&1; then
    sudo apt-get install -y dropbear-bin >/dev/null 2>&1 || true
fi
DROPBEAR_BIN="$(command -v dropbear || true)"
DROPBEARKEY_BIN="$(command -v dropbearkey || true)"
if [ -n "${DROPBEAR_BIN}" ] && [ -f "${DROPBEAR_BIN}" ]; then
    cp -a "${DROPBEAR_BIN}" "${STAGING}/usr/sbin/dropbear"
    chmod 755 "${STAGING}/usr/sbin/dropbear"
    for lib in $(ldd "${DROPBEAR_BIN}" 2>/dev/null | grep -o '/[^ ]*' || true); do
        copy_lib "${lib}"
    done
fi
if [ -n "${DROPBEARKEY_BIN}" ] && [ -f "${DROPBEARKEY_BIN}" ]; then
    cp -a "${DROPBEARKEY_BIN}" "${STAGING}/usr/sbin/dropbearkey"
    chmod 755 "${STAGING}/usr/sbin/dropbearkey"
    for lib in $(ldd "${DROPBEARKEY_BIN}" 2>/dev/null | grep -o '/[^ ]*' || true); do
        copy_lib "${lib}"
    done
fi
SSH_KEY="${SCRIPT_DIR}/ssh_id_ed25519"
if [ ! -f "${SSH_KEY}" ]; then
    ssh-keygen -t ed25519 -N "" -f "${SSH_KEY}" >/dev/null
fi
mkdir -p "${STAGING}/root/.ssh" "${STAGING}/etc/dropbear" "${STAGING}/var/run" "${STAGING}/var/log"
chmod 755 "${STAGING}/root"
chmod 700 "${STAGING}/root/.ssh"
cp -a "${SSH_KEY}.pub" "${STAGING}/root/.ssh/authorized_keys"
chmod 600 "${STAGING}/root/.ssh/authorized_keys"
if command -v dropbearkey >/dev/null 2>&1; then
    dropbearkey -t ed25519 -f "${STAGING}/etc/dropbear/dropbear_ed25519_host_key" >/dev/null 2>&1 || true
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
    "libnftables.so"
    "libnftnl.so"
    "libmnl.so"
    "libjansson.so"
)
for lib in "${EXTRA_LIBS[@]}"; do
    found_libs=$(find /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu -name "${lib}*" 2>/dev/null || true)
    for found_lib in ${found_libs}; do
        copy_lib "${found_lib}"
    done
done

# Ensure standard dynamic linker paths
if [ -f /lib64/ld-linux-x86-64.so.2 ]; then
    copy_lib /lib64/ld-linux-x86-64.so.2
    cp -a /lib64/ld-linux-x86-64.so.2 "${STAGING}/usr/lib64/ld-linux-x86-64.so.2" 2>/dev/null || true
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

# Copy /etc/alternatives (critical for Debian/Ubuntu symlinks like awk, cc, c++, editor)
if [ -d /etc/alternatives ]; then
    echo "  -> Copying /etc/alternatives symlinks..."
    mkdir -p "${STAGING}/etc"
    cp -a /etc/alternatives "${STAGING}/etc/"
fi

for ef in /etc/os-release /etc/environment /etc/magic /etc/mime.types; do
    if [ -f "${ef}" ]; then
        cp -a "${ef}" "${STAGING}/etc/" 2>/dev/null || true
    fi
done

# APT package manager and dpkg status for guest package installation
if [ -d /etc/apt ]; then
    echo "  -> Copying /etc/apt configuration..."
    mkdir -p "${STAGING}/etc/apt"
    cp -a /etc/apt/* "${STAGING}/etc/apt/" 2>/dev/null || true
fi
mkdir -p "${STAGING}/var/lib/dpkg/info" "${STAGING}/var/lib/dpkg/updates" \
         "${STAGING}/var/lib/apt/lists/partial" "${STAGING}/var/cache/apt/archives/partial" \
         "${STAGING}/var/log/apt"
if [ -f /var/lib/dpkg/status ]; then
    echo "  -> Copying /var/lib/dpkg/status..."
    cp -a /var/lib/dpkg/status "${STAGING}/var/lib/dpkg/status" 2>/dev/null || true
    touch "${STAGING}/var/lib/dpkg/available"
fi


# Sudo configuration: copy exact host sudoers file to preserve file size fidelity for CRIU,
# and place passwordless permissions into sudoers.d dropin
mkdir -p "${STAGING}/etc/sudoers.d"
if [ -f /etc/sudoers ]; then
    cp -a /etc/sudoers "${STAGING}/etc/sudoers" 2>/dev/null || true
else
    cat << 'EOF' > "${STAGING}/etc/sudoers"
Defaults	env_reset
Defaults	mail_badpass
Defaults	secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
root	ALL=(ALL:ALL) ALL
EOF
fi
cat << 'EOF' > "${STAGING}/etc/sudoers.d/99-runner-nopasswd"
root ALL=(ALL:ALL) NOPASSWD: ALL
runner ALL=(ALL:ALL) NOPASSWD: ALL
ALL ALL=(ALL:ALL) NOPASSWD: ALL
EOF
chmod 0440 "${STAGING}/etc/sudoers" 2>/dev/null || true
chmod 0440 "${STAGING}/etc/sudoers.d/"* 2>/dev/null || true

# PAM and security configuration
if [ -d /etc/pam.d ]; then
    mkdir -p "${STAGING}/etc/pam.d"
    cp -a /etc/pam.d/* "${STAGING}/etc/pam.d/" 2>/dev/null || true
fi
if [ -d /etc/security ]; then
    mkdir -p "${STAGING}/etc/security"
    cp -a /etc/security/* "${STAGING}/etc/security/" 2>/dev/null || true
fi




# SSL certificates
mkdir -p "${STAGING}/etc/ssl" "${STAGING}/usr/lib/ssl"
if [ -d /etc/ssl/certs ]; then
    cp -a /etc/ssl/certs "${STAGING}/etc/ssl/"
    ln -sf /etc/ssl/certs "${STAGING}/usr/lib/ssl/certs"
    ln -sf /etc/ssl/certs/ca-certificates.crt "${STAGING}/usr/lib/ssl/cert.pem" 2>/dev/null || true
fi

# Locale archive plus C.utf8 (dummy bash maps LC_CTYPE from generated locales)
if [ -d /usr/lib/locale ]; then
    mkdir -p "${STAGING}/usr/lib/locale"
    if [ -f /usr/lib/locale/locale-archive ]; then
        cp -a /usr/lib/locale/locale-archive "${STAGING}/usr/lib/locale/locale-archive"
    fi
    for loc in C.utf8 C.UTF-8; do
        if [ -e "/usr/lib/locale/${loc}" ]; then
            cp -a "/usr/lib/locale/${loc}" "${STAGING}/usr/lib/locale/"
        fi
    done
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
127.0.0.1   localhost qemu-restore-vm
::1         localhost ip6-localhost ip6-loopback qemu-restore-vm
EOF


cat << 'EOF' > "${STAGING}/etc/resolv.conf"
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 168.63.129.16
nameserver 10.0.2.3
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
set +e

progress() {
    msg="$*"
    echo "[GUEST] ${msg}"
    # Only the 9p checkpoint share is visible on the host helper.
    if [ -f /run/checkpoint/state.txt ]; then
        echo "${msg}" >> /run/checkpoint/guest_progress.txt 2>/dev/null || true
        /bin/busybox sync 2>/dev/null || true
    fi
}

# Mount pseudo-filesystems
/bin/busybox mount -t proc proc /proc 2>/dev/null || true
/bin/busybox mount -t sysfs sysfs /sys 2>/dev/null || true
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
/bin/busybox mkdir -p /dev/pts /dev/shm /run 2>/dev/null || true
/bin/busybox mount -t devpts devpts /dev/pts 2>/dev/null || true
/bin/busybox mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true
/bin/busybox mount -t tmpfs tmpfs /tmp 2>/dev/null || true
/bin/busybox mount -t tmpfs -o mode=0755 tmpfs /run 2>/dev/null || true
/bin/busybox chmod 1777 /tmp /dev/shm 2>/dev/null || true
/bin/busybox mkdir -p /sys/fs/cgroup 2>/dev/null || true
/bin/busybox mount -t cgroup2 cgroup2 /sys/fs/cgroup 2>/dev/null || true

# Set VM hostname
/bin/busybox hostname qemu-restore-vm 2>/dev/null || true

# Ensure /etc/sudoers is owned by root (uid 0) with mode 0440
/bin/busybox chown 0:0 /etc/sudoers 2>/dev/null || true
/bin/busybox chown -R 0:0 /etc/sudoers.d 2>/dev/null || true
/bin/busybox chmod 0440 /etc/sudoers 2>/dev/null || true

# Set max pid limit
echo 4194304 > /proc/sys/kernel/pid_max 2>/dev/null || true

# Load diagnostic kernel modules
for mod in inet_diag tcp_diag unix_diag af_packet_diag netlink_diag veth nfnetlink nf_tables; do
    if [ -f "/modules/${mod}.ko" ]; then
        if /bin/busybox insmod "/modules/${mod}.ko" 2>&1; then
            echo "[GUEST] [OK] Loaded module ${mod}"
        else
            echo "[GUEST] [WARN] Failed to load module ${mod}"
        fi
    else
        echo "[GUEST] [WARN] Module file /modules/${mod}.ko not found"
    fi
done

# Load 9p virtio filesystem and overlay modules in dependency order
for mod in netfs 9pnet 9pnet_virtio 9p overlay; do
    if [ -f "/modules/${mod}.ko" ]; then
        if /bin/busybox insmod "/modules/${mod}.ko" 2>&1; then
            echo "[GUEST] [OK] Loaded module ${mod}"
        else
            echo "[GUEST] [FAIL] Failed to load module ${mod}"
        fi
    else
        echo "[GUEST] [FAIL] Module /modules/${mod}.ko not found!"
    fi
done

# Mount checkpoint first to read net_mode (Porter TAP vs user NAT).
/bin/busybox mkdir -p /run/checkpoint 2>/dev/null || true
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=none checkpoint /run/checkpoint 2>&1 \
    && echo "[GUEST] [OK] Mounted checkpoint share in /run" \
    || echo "[GUEST] [FAIL] Checkpoint share mount failed!"
progress "checkpoint 9p mounted"

if [ -f /run/checkpoint/checkpoint_dir.txt ]; then
    HOST_CP="$(/bin/busybox cat /run/checkpoint/checkpoint_dir.txt 2>/dev/null || true)"
fi

NET_MODE="user"
if [ -f /run/checkpoint/net_mode.txt ]; then
    NET_MODE="$(/bin/busybox cat /run/checkpoint/net_mode.txt 2>/dev/null || echo user)"
fi
echo "[GUEST] net_mode=${NET_MODE}"

# Configure networking: TAP mode uses eth0 for workload (IP applied at restore) + eth1 user NAT for SSH.
/bin/busybox ifconfig lo up 2>/dev/null || true
if [ "${NET_MODE}" = "tap" ]; then
    /bin/busybox ifconfig eth0 up 2>/dev/null || true
    if /bin/busybox ifconfig eth1 10.0.2.15 netmask 255.255.255.0 up 2>/dev/null; then
        /bin/busybox route add default gw 10.0.2.2 dev eth1 2>/dev/null || true
        echo "[GUEST] [OK] tap mode: eth0 up (workload IP at restore), eth1=10.0.2.15 SSH"
    else
        echo "[GUEST] WARNING: eth1 (SSH) not found in tap mode!"
    fi
else
    if /bin/busybox ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up 2>/dev/null; then
        /bin/busybox route add default gw 10.0.2.2 dev eth0 2>/dev/null || true
        echo "[GUEST] [OK] eth0 configured: IP 10.0.2.15, Gateway 10.0.2.2"
    else
        echo "[GUEST] WARNING: eth0 interface not found!"
    fi
fi

echo "=========================================================="
echo "=== QEMU Guest VM Booted for GitHub Runner Restore     ==="
echo "=== Hostname: $(/bin/busybox hostname 2>/dev/null || echo guest) ==="
echo "=== Kernel:   $(/bin/busybox uname -r 2>/dev/null || echo linux) ==="
echo "=== PID 1:    /bin/busybox sh /init                    ==="
echo "=========================================================="

# Check if Host Rootfs (read-only) is available for OverlayFS projection
/bin/busybox mkdir -p /run/host_root /run/cow /newroot 2>/dev/null || true
if /bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose,ro host_root /run/host_root 2>/dev/null; then
    echo "[GUEST] [OK] Mounted host_root read-only in /run"
    /bin/busybox mkdir -p /run/cow/upper /run/cow/work /newroot 2>/dev/null || true

    if /bin/busybox mount -t overlay overlay -o lowerdir=/run/host_root,upperdir=/run/cow/upper,workdir=/run/cow/work,index=off,metacopy=off /newroot 2>&1; then
        echo "[GUEST] [OK] Mounted unified OverlayFS on /newroot"

        # Prepare newroot directories
        /bin/busybox mkdir -p /newroot/tmp /newroot/run /newroot/mnt /newroot/dev /newroot/proc /newroot/sys /newroot/etc/dropbear 2>/dev/null || true

        # Mount a dedicated tmpfs over /newroot/root so root homedir is always clean, writable, and independent of host permissions
        /bin/busybox mount -t tmpfs -o mode=0700 tmpfs /newroot/root 2>/dev/null || true
        /bin/busybox mkdir -p /newroot/root/.ssh 2>/dev/null || true
        /bin/busybox chmod 700 /newroot/root /newroot/root/.ssh 2>/dev/null || true
        /bin/busybox cp -a /root/.ssh/* /newroot/root/.ssh/ 2>/dev/null || true
        /bin/busybox chmod 600 /newroot/root/.ssh/authorized_keys 2>/dev/null || true

        # Copy Dropbear keys from initramfs into newroot
        /bin/busybox cp -a /etc/dropbear/* /newroot/etc/dropbear/ 2>/dev/null || true

        # Seed disk detection & mount for dynamic state (/home, /var)
        /bin/busybox mkdir -p /run/seed /newroot/home /newroot/var 2>/dev/null || true
        SEED_DEV=""
        for dev in /dev/vda /dev/vdb /dev/vdc; do
            if [ -b "${dev}" ]; then
                SEED_DEV="${dev}"
                break
            fi
        done

        if [ -n "${SEED_DEV}" ]; then
            echo "[GUEST] [OK] Found seed block device ${SEED_DEV}, mounting for /home and /var..."
            if /bin/busybox mount "${SEED_DEV}" /run/seed 2>/dev/null; then
                if [ -d /run/seed/home ]; then
                    /bin/busybox mount --bind /run/seed/home /newroot/home 2>/dev/null || true
                    echo "[GUEST] [OK] Mounted private ext4 /home from seed disk"
                fi
                if [ -d /run/seed/var ]; then
                    /bin/busybox mount --bind /run/seed/var /newroot/var 2>/dev/null || true
                    echo "[GUEST] [OK] Mounted private ext4 /var from seed disk"
                fi
                if [ -d /run/seed/root ]; then
                    /bin/busybox mount --bind /run/seed/root /newroot/root 2>/dev/null || true
                fi
            else
                echo "[GUEST] [WARN] Failed to mount seed device ${SEED_DEV}"
            fi
        else
            echo "[GUEST] [INFO] No seed block device found, /home and /var backed by overlay"
        fi

        # Ensure root SSH authorized keys are present in /newroot/root/.ssh even if seed mounted over /root
        /bin/busybox mkdir -p /newroot/root/.ssh 2>/dev/null || true
        /bin/busybox chmod 700 /newroot/root /newroot/root/.ssh 2>/dev/null || true
        /bin/busybox cp -a /root/.ssh/* /newroot/root/.ssh/ 2>/dev/null || true
        /bin/busybox chmod 600 /newroot/root/.ssh/authorized_keys 2>/dev/null || true

        # Ensure /newroot/etc/shadow is readable so Dropbear can authenticate root
        if ! /bin/busybox test -r /newroot/etc/shadow 2>/dev/null; then
            cat << 'SHADOWEOF' > /newroot/etc/shadow
root:*:19700:0:99999:7:::
daemon:*:19700:0:99999:7:::
bin:*:19700:0:99999:7:::
sys:*:19700:0:99999:7:::
sync:*:19700:0:99999:7:::
games:*:19700:0:99999:7:::
man:*:19700:0:99999:7:::
lp:*:19700:0:99999:7:::
mail:*:19700:0:99999:7:::
news:*:19700:0:99999:7:::
uucp:*:19700:0:99999:7:::
proxy:*:19700:0:99999:7:::
www-data:*:19700:0:99999:7:::
backup:*:19700:0:99999:7:::
list:*:19700:0:99999:7:::
irc:*:19700:0:99999:7:::
gnats:*:19700:0:99999:7:::
nobody:*:19700:0:99999:7:::
runner:*:19700:0:99999:7:::
SHADOWEOF
            chmod 640 /newroot/etc/shadow 2>/dev/null || true
        fi

        # Exclude host identity files and replace /etc/fstab to prevent 90s device timeouts
        rm -f /newroot/etc/machine-id /newroot/etc/ssh/ssh_host_* 2>/dev/null || true
        touch /newroot/etc/machine-id 2>/dev/null || true
        cat << 'FSTABEOF' > /newroot/etc/fstab
# /etc/fstab: MicroVM guest filesystem table
/dev/root / ext4 defaults 0 0
FSTABEOF

        # Mark VM
        /bin/busybox touch /newroot/tmp/is_vm 2>/dev/null || true
        echo "is_vm" > /newroot/tmp/is_vm 2>/dev/null || true

        # Static DNS
        cat << 'DNSEOF' > /newroot/etc/resolv.conf
nameserver 192.168.100.1
nameserver 8.8.8.8
nameserver 1.1.1.1
DNSEOF

        # Mask conflicting systemd units in overlay upperdir
        mkdir -p /newroot/etc/systemd/system /newroot/etc/systemd/network 2>/dev/null || true
        for svc in $(find /newroot/etc/systemd/system -name 'actions.runner*.service' 2>/dev/null); do
            ln -sf /dev/null "/newroot/etc/systemd/system/$(basename "$svc")" 2>/dev/null || true
        done
        for svc in walinuxagent.service cloud-init.service cloud-init-local.service \
                   cloud-config.service cloud-final.service azure-setup.service \
                   unattended-upgrades.service apt-daily.service apt-daily.timer \
                   apt-daily-upgrade.service apt-daily-upgrade.timer \
                   snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service snapd.mounts.target \
                   apparmor.service \
                   systemd-udev-settle.service \
                   systemd-networkd.service systemd-networkd-wait-online.service \
                   NetworkManager.service; do
            ln -sf /dev/null "/newroot/etc/systemd/system/${svc}" 2>/dev/null || true
        done
        cat << 'NETEOF' > /newroot/etc/systemd/network/99-unmanaged-all.network
[Match]
Name=eth* tap* lo

[Link]
Unmanaged=yes
NETEOF

        # Link checkpoint into newroot & stage images
        mkdir -p /newroot/tmp/restore /newroot/mnt/checkpoint 2>/dev/null || true
        /bin/busybox cp -a /run/checkpoint/*.img /run/checkpoint/*.txt /newroot/tmp/restore/ 2>/dev/null || true
        /bin/busybox chmod -R 777 /newroot/tmp/restore 2>/dev/null || true
        /bin/busybox ln -sf /run/checkpoint /newroot/tmp/runner_checkpoint 2>/dev/null || true
        /bin/busybox ln -sf /run/checkpoint /newroot/mnt/checkpoint 2>/dev/null || true
        if [ -n "${HOST_CP:-}" ]; then
            /bin/busybox mkdir -p "$(/bin/busybox dirname "/newroot/${HOST_CP}")" 2>/dev/null || true
            /bin/busybox ln -sf /run/checkpoint "/newroot/${HOST_CP}" 2>/dev/null || true
        fi

        # Install t9_restore.sh in newroot
        /bin/busybox cp -a /usr/sbin/t9_restore.sh /newroot/usr/sbin/t9_restore.sh 2>/dev/null || true
        /bin/busybox chmod 755 /newroot/usr/sbin/t9_restore.sh 2>/dev/null || true

        # Mask host OpenSSH so it doesn't conflict with appliance Dropbear on port 22
        ln -sf /dev/null /newroot/etc/systemd/system/ssh.service 2>/dev/null || true
        ln -sf /dev/null /newroot/etc/systemd/system/ssh.socket 2>/dev/null || true
        ln -sf /dev/null /newroot/etc/systemd/system/sshd.service 2>/dev/null || true

        # Create Dropbear systemd service unit
        cat << 'DROPEOF' > /newroot/etc/systemd/system/dropbear.service
[Unit]
Description=MicroVM Dropbear SSH Server
DefaultDependencies=no
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/dropbear -R -E -s -p 22 -F
Restart=always

[Install]
WantedBy=multi-user.target
DROPEOF
        mkdir -p /newroot/etc/systemd/system/multi-user.target.wants 2>/dev/null || true
        ln -sf /etc/systemd/system/dropbear.service /newroot/etc/systemd/system/multi-user.target.wants/dropbear.service 2>/dev/null || true

        # Unmount non-moved temporary filesystems in initramfs
        /bin/busybox umount /dev/pts /dev/shm /tmp /sys/fs/cgroup 2>/dev/null || true
        /bin/busybox umount /sys /proc /dev 2>/dev/null || true

        # Mount pristine virtual filesystems directly inside newroot
        /bin/busybox mount -t proc proc /newroot/proc 2>/dev/null || true
        /bin/busybox mount -t sysfs sysfs /newroot/sys 2>/dev/null || true
        /bin/busybox mount -t devtmpfs devtmpfs /newroot/dev 2>/dev/null || true
        /bin/busybox mount -o move /run /newroot/run 2>/dev/null || true

        echo "[GUEST] Switching root to OverlayFS and handing PID 1 to host systemd via run-init..."
        exec /sbin/run-init /newroot /sbin/init < /newroot/dev/console > /newroot/dev/console 2>&1
        echo "[GUEST] [FATAL] exec run-init returned: $?"
    else
        echo "[GUEST] [WARN] OverlayFS mount failed, falling back to legacy 9p mounts"
    fi
else
    echo "[GUEST] [INFO] host_root share not present, using legacy 9p mounts"
fi

# Fallback: Mount individual 9p shares
/bin/busybox mkdir -p /home/runner /host_tmp /mnt/usrlib /host_usr /host_bin /host_lib /host_lib64 /host_opt /opt /usr/share/dotnet

echo "[GUEST] Mounting 9p shares..."
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose host_runner /home/runner 2>&1 && echo "[GUEST] [OK] Mounted host_runner share" || echo "[GUEST] [FAIL] host_runner mount failed!"
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose host_tmp /host_tmp 2>&1 && echo "[GUEST] [OK] Mounted host_tmp share" || echo "[GUEST] [FAIL] host_tmp mount failed!"
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose usrlib /mnt/usrlib 2>&1 && echo "[GUEST] [OK] Mounted usrlib share" || echo "[GUEST] [WARN] usrlib mount failed (using initramfs libs)"
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose host_usr /host_usr 2>&1 && echo "[GUEST] [OK] Mounted host_usr share" || echo "[GUEST] [WARN] host_usr mount failed"
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose host_bin /host_bin 2>&1 && echo "[GUEST] [OK] Mounted host_bin share" || echo "[GUEST] [WARN] host_bin mount failed"
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose host_lib /host_lib 2>&1 && echo "[GUEST] [OK] Mounted host_lib share" || echo "[GUEST] [WARN] host_lib mount failed"
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose host_lib64 /host_lib64 2>&1 && echo "[GUEST] [OK] Mounted host_lib64 share" || echo "[GUEST] [WARN] host_lib64 mount failed"
if /bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose host_opt /host_opt 2>/dev/null; then
    echo "[GUEST] [OK] Mounted host_opt share"
else
    echo "[GUEST] [INFO] host_opt share not present"
fi
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose dotnet /usr/share/dotnet 2>&1 && echo "[GUEST] [OK] Mounted dotnet share" || echo "[GUEST] [WARN] dotnet mount failed"


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

# Inspect checkpoint share (restore is invoked later over SSH, not from PID 1)
echo "[GUEST] Inspecting /mnt/checkpoint contents:"
/bin/busybox ls -lh /mnt/checkpoint 2>&1 || true

/bin/busybox mkdir -p /tmp/restore
echo "[GUEST] Copying checkpoint images to local tmpfs..."
/bin/busybox cp -a /mnt/checkpoint/*.img /mnt/checkpoint/*.txt /tmp/restore/ 2>/dev/null || true
/bin/busybox chmod -R 777 /tmp/restore 2>/dev/null || true
/bin/busybox chmod 755 /
echo "[GUEST] Testing CRIU binary..."
/bin/busybox ls -la /usr/sbin/criu /usr/sbin/dropbear /lib64/ld-linux-x86-64.so.2 2>&1 || true
/usr/sbin/criu --version 2>&1 || echo "[GUEST] Warning: /usr/sbin/criu failed"
progress "appliance criu ok"

echo "[GUEST] Starting dropbear SSH on :22"
/bin/busybox mkdir -p /var/run /var/log /etc/dropbear /root/.ssh
# initramfs was packed as the host runner user; dropbear requires uid 0 and mode 755.
/bin/busybox chown -R 0:0 /root /etc/dropbear 2>/dev/null || true
/bin/busybox chmod 755 /root
/bin/busybox chmod 700 /root/.ssh
/bin/busybox chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
/bin/busybox ls -ld / /root /root/.ssh
/usr/sbin/dropbear -R -E -s -p 22 2>&1 || /usr/sbin/dropbear -R -E -p 22 2>&1 || echo "[GUEST] [FAIL] dropbear"
progress "dropbear started"
echo SSH_READY
echo "[GUEST] SSH_READY — waiting for host to run /usr/sbin/t9_restore.sh"
progress "SSH_READY"

# Stay up. Host helper logs in and runs restore. Poweroff is host-driven.
while true; do
    /bin/busybox sleep 30
    progress "appliance still up"
done
EOF
chmod 755 "${STAGING}/init"

cat << 'RESTOREEOF' > "${STAGING}/usr/sbin/t9_restore.sh"
#!/bin/busybox sh
# Run from SSH after appliance boot. Does not dump; only restore.
set +e
if [ -f /mnt/checkpoint/state.txt ]; then
    echo "t9_restore start" >> /mnt/checkpoint/guest_progress.txt
fi
if [ ! -f /tmp/restore/inventory.img ]; then
    echo "[GUEST] t9_restore: copying images"
    mkdir -p /tmp/restore
    cp -a /mnt/checkpoint/*.img /mnt/checkpoint/*.txt /tmp/restore/ 2>/dev/null || true
    chmod -R 777 /tmp/restore 2>/dev/null || true
else
    echo "[GUEST] t9_restore: images already present in /tmp/restore (skipping redundant copy)"
fi
chmod 755 / 2>/dev/null || true
echo "[GUEST] Marking VM environment for restored processes"
touch /tmp/is_vm
echo "is_vm" > /tmp/is_vm
/bin/busybox ln -s /mnt/checkpoint /tmp/runner_checkpoint 2>/dev/null || true
echo "is_vm marker created" >> /mnt/checkpoint/guest_progress.txt 2>/dev/null || true
echo "[GUEST] Binding host /usr /bin /lib for criu path fidelity"
for pair in /host_usr:/usr /host_bin:/bin /host_lib:/lib /host_lib64:/lib64 /host_opt:/opt; do
    src="${pair%%:*}"
    dst="${pair##*:}"
    if [ -d "${src}" ]; then
        /bin/busybox mkdir -p "${dst}"
        /bin/busybox mount --bind "${src}" "${dst}" 2>/dev/null \
            && echo "[GUEST] bind ${dst}" \
            || echo "[GUEST] WARN bind ${dst} failed"
    fi
done
echo "host_rootfs_bind done" >> /mnt/checkpoint/guest_progress.txt 2>/dev/null || true

/bin/busybox mkdir -p /var/run /run
if [ -x /usr/bin/socat ]; then
    echo "[GUEST] Launching Docker UNIX socket bridge to 192.168.100.1:2375"
    /usr/bin/socat UNIX-LISTEN:/var/run/docker.sock,fork,mode=666 TCP:192.168.100.1:2375 &
    /bin/busybox ln -sf /var/run/docker.sock /run/docker.sock 2>/dev/null || true
    echo "DOCKER_HOST=unix:///var/run/docker.sock" >> /etc/environment 2>/dev/null || true
fi


if [ -f /opt_sudo_shim ]; then
    echo "[GUEST] Installing setuid sudo shim over /usr/bin/sudo"
    /bin/busybox mount --bind /opt_sudo_shim /usr/bin/sudo 2>/dev/null || true
    /bin/busybox mount --bind /opt_sudo_shim /usr/local/bin/sudo 2>/dev/null || true
fi


FROZEN=/mnt/checkpoint/frozen_files
if [ -f "${FROZEN}/manifest.tsv" ]; then
    echo "[GUEST] Applying frozen file overlays before criu restore"
    echo "frozen_overlays start" >> /mnt/checkpoint/guest_progress.txt 2>/dev/null || true
    while IFS="$(printf '\t')" read -r relpath size_bytes mode; do
        [ -n "${relpath}" ] || continue
        [ "${relpath}" = "rel_path" ] && continue
        src="${FROZEN}/${relpath}"
        dst="/${relpath}"
        if [ ! -f "${src}" ]; then
            echo "[GUEST] WARN missing frozen ${src}"
            continue
        fi
        /bin/busybox mkdir -p "$(/bin/busybox dirname "${dst}")"
        /bin/busybox mount --bind "${src}" "${dst}" 2>/dev/null \
            && echo "[GUEST] overlay ${dst} size=${size_bytes}" \
            || echo "[GUEST] WARN overlay failed ${dst}"
    done < "${FROZEN}/manifest.tsv"
    echo "frozen_overlays done" >> /mnt/checkpoint/guest_progress.txt 2>/dev/null || true
fi
if [ -f /mnt/checkpoint/network_spec.env ]; then
    echo "[GUEST] Reconstructing network from network_spec.env (before criu restore)"
    # shellcheck disable=SC1091
    . /mnt/checkpoint/network_spec.env
    /bin/busybox ifconfig lo up 2>/dev/null || true
    /bin/busybox ifconfig eth0 up 2>/dev/null || true
    if [ -n "${GUEST_IP:-}" ]; then
        echo "[GUEST] TC redirect topology: eth0 ${GUEST_IP}/${TAP_PREFIX:-24}, lo ${LOCAL_IP}/32, gw ${HOST_GW}"
        /bin/busybox ifconfig eth0 "${GUEST_IP}" netmask "${TAP_NETMASK:-255.255.255.0}" up 2>/dev/null \
            && echo "[GUEST] eth0 ${GUEST_IP}" \
            || echo "[GUEST] WARN eth0 addr failed"
        /bin/busybox route del default 2>/dev/null || true
        /bin/busybox route add default gw "${HOST_GW}" dev eth0 2>/dev/null \
            && echo "[GUEST] default via ${HOST_GW} dev eth0" \
            || echo "[GUEST] WARN default route failed"
        /bin/busybox ip addr add "${LOCAL_IP}/32" dev eth0 2>/dev/null || true
        /bin/busybox ip addr add "${LOCAL_IP}/32" dev lo 2>/dev/null || true
        /bin/busybox sysctl -w net.ipv4.ip_nonlocal_bind=1 2>/dev/null || true
        /bin/busybox sysctl -w net.ipv4.conf.all.accept_local=1 2>/dev/null || true
        /bin/busybox sysctl -w net.ipv4.conf.eth0.accept_local=1 2>/dev/null || true
        /bin/busybox sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
        /bin/busybox sysctl -w net.ipv4.conf.eth0.rp_filter=0 2>/dev/null || true
        /bin/busybox sysctl -w net.ipv4.conf.lo.rp_filter=0 2>/dev/null || true
        /bin/busybox ip link set eth0 promisc on 2>/dev/null || true
    else
        /bin/busybox ifconfig eth0 "${LOCAL_IP}" netmask "${NETMASK}" up 2>/dev/null \
            && echo "[GUEST] eth0 ${LOCAL_IP}/${PREFIX}" \
            || echo "[GUEST] WARN eth0 addr failed"
        /bin/busybox route del default 2>/dev/null || true
        /bin/busybox route add default gw "${HOST_GW}" dev eth0 2>/dev/null \
            && echo "[GUEST] default via ${HOST_GW} dev eth0" \
            || echo "[GUEST] WARN default route failed"
    fi
    /bin/busybox ip addr show 2>/dev/null >> /mnt/checkpoint/post_restore_diag.txt 2>/dev/null || true
    /bin/busybox ip route show 2>/dev/null >> /mnt/checkpoint/post_restore_diag.txt 2>/dev/null || true
    echo "network_reconstruct ok LOCAL_IP=${LOCAL_IP} GUEST_IP=${GUEST_IP:-none}" >> /mnt/checkpoint/guest_progress.txt 2>/dev/null || true
fi
TCP_FLAG="--tcp-close"
if [ -f /mnt/checkpoint/criu_tcp_mode.txt ]; then
    case "$(/bin/busybox cat /mnt/checkpoint/criu_tcp_mode.txt)" in
        close) TCP_FLAG="--tcp-close" ;;
        established) TCP_FLAG="--tcp-established" ;;
    esac
fi
echo "[GUEST] t9_restore: criu restore ${TCP_FLAG}"
export PATH="/sbin:/usr/sbin:/bin:/usr/bin:${PATH:-}"
/sbin/criu restore -d -D /tmp/restore \
    --shell-job --file-locks --ext-unix-sk --skip-file-rwx-check "${TCP_FLAG}" \
    --ghost-limit 32M \
    -v4 -o /mnt/checkpoint/restore_log.txt
RC=$?
echo "[GUEST] t9_restore rc=${RC}"
echo "${RC}" > /mnt/checkpoint/restore.rc
echo "criu restore rc=${RC}" >> /mnt/checkpoint/guest_progress.txt 2>/dev/null || true
if [ "${RC}" -ne 0 ]; then
    echo "[GUEST] restore_log errors:"
    /bin/busybox grep -E 'Error|error|WARN|Failed|failed' /mnt/checkpoint/restore_log.txt 2>/dev/null \
        | /bin/busybox tail -n 40 || true
    echo "[GUEST] restore_log tail:"
    /bin/busybox tail -n 30 /mnt/checkpoint/restore_log.txt 2>/dev/null || true
    sync
    exit ${RC}
fi

DIAG=/mnt/checkpoint/post_restore_diag.txt
echo "=== post-restore diagnostics ===" >> "${DIAG}"
echo "is_vm=$(/bin/busybox cat /tmp/is_vm 2>/dev/null || echo missing)" >> "${DIAG}"

# Dump-time SIGSTOP leaves restored tasks stopped (T) in the guest; resume them.
echo "[GUEST] SIGCONT stopped restored processes" >> "${DIAG}"
CONT_COUNT=0
for pass in 1 2 3; do
    for pid in $(/bin/busybox ls /proc 2>/dev/null | /bin/busybox grep -E '^[0-9]+$'); do
        [ "${pid}" -eq 1 ] && continue
        state="$(/bin/busybox awk '/^State:/ {print $2; exit}' /proc/${pid}/status 2>/dev/null || true)"
        [ "${state}" = "T" ] || continue
        cmd="$(/bin/busybox tr '\0' ' ' < /proc/${pid}/cmdline 2>/dev/null || true)"
        echo "pass=${pass} SIGCONT pid=${pid} state=${state} cmd=${cmd}" >> "${DIAG}"
        /bin/busybox kill -CONT "${pid}" 2>/dev/null || true
        CONT_COUNT=$((CONT_COUNT + 1))
    done
    /bin/busybox sleep 1
done
echo "sigcont_count=${CONT_COUNT}" >> "${DIAG}"
echo "guest_sigcont count=${CONT_COUNT}" >> /mnt/checkpoint/guest_progress.txt 2>/dev/null || true

echo "--- process scan ---" >> "${DIAG}"
/bin/busybox ps 2>/dev/null | /bin/busybox head -n 30 >> "${DIAG}" || true
for pid in $(/bin/busybox ls /proc 2>/dev/null | /bin/busybox grep -E '^[0-9]+$'); do
    cmd="$(/bin/busybox tr '\0' ' ' < /proc/${pid}/cmdline 2>/dev/null || true)"
    echo "${cmd}" | /bin/busybox grep -qE 'Runner\.(Worker|Listener)|is_vm_wait' || continue
    state="$(/bin/busybox awk '/^State:/ {print $2; exit}' /proc/${pid}/status 2>/dev/null || true)"
    echo "pid=${pid} state=${state} cmd=${cmd}" >> "${DIAG}"
    /bin/busybox ls -la "/proc/${pid}/fd" 2>/dev/null | /bin/busybox head -n 15 >> "${DIAG}" || true
done
echo "post_restore_diag written" >> /mnt/checkpoint/guest_progress.txt 2>/dev/null || true

# Host helper writes migrator_ok after this script returns; restored bash waits on that.
# Give restored VM processes time to reach vm_migrate_step_done (branch mode) or vm_done (legacy).
WAIT_VM=0
while [ ! -f /mnt/checkpoint/vm_migrate_step_done ] \
    && [ ! -f /mnt/checkpoint/vm_done ] \
    && [ "${WAIT_VM}" -lt 5 ]; do
    /bin/busybox sleep 1
    WAIT_VM=$((WAIT_VM + 1))
done
echo "vm_branch_wait_s=${WAIT_VM}" >> "${DIAG}"
if [ -f /mnt/checkpoint/vm_migrate_step_done ]; then
    echo "vm_migrate_step_done=$(/bin/busybox cat /mnt/checkpoint/vm_migrate_step_done)" >> "${DIAG}"
elif [ -f /mnt/checkpoint/vm_done ]; then
    echo "vm_done tag=$(/bin/busybox cat /mnt/checkpoint/vm_done)" >> "${DIAG}"
else
    echo "[GUEST] branch markers not yet present (host will write migrator_ok next)" >> "${DIAG}"
fi
sync
exit 0
RESTOREEOF
chmod 755 "${STAGING}/usr/sbin/t9_restore.sh"

# 7. Package initramfs
echo "[7/7] Packing initramfs.cpio.gz..."
chmod -R a+rX "${STAGING}" 2>/dev/null || sudo chmod -R a+rX "${STAGING}"
(
    cd "${STAGING}"
    find . -mindepth 1 | cpio -H newc -o --owner 0:0 2>/dev/null | gzip -1 > "${INITRAMFS_OUT}"
)

INITRAMFS_SIZE=$(du -h "${INITRAMFS_OUT}" | awk '{print $1}')
echo "=== Assembly Complete: ${INITRAMFS_OUT} (${INITRAMFS_SIZE}) ==="
exit 0
