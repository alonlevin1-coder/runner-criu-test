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
mkdir -p "${STAGING}"/{bin,sbin,usr/bin,usr/sbin,usr/lib,usr/share,lib,lib64,etc,proc,sys,dev,dev/pts,dev/shm,tmp,run,root,home/runner,mnt/checkpoint,host_tmp,mnt/usrlib,host_usr,host_bin,host_lib,host_lib64,host_opt,opt,usr/share/dotnet,modules}


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
    pivot_root switch_root nsenter
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



# 3. Guest kernel modules. T9_KERNEL=host packs $(uname -r) only (must match
#    /boot/vmlinuz). pin keeps git appliance/modules for the repo bzImage.
echo "[3/7] Packaging guest kernel modules..."
mkdir -p "${STAGING}/modules"
T9_KERNEL="${T9_KERNEL:-pin}"
pack_kmod() {
    local name="$1" src
    [ -n "${KMOD_VER:-}" ] || return 0
    src="$(find "/lib/modules/${KMOD_VER}" \( -name "${name}.ko.zst" -o -name "${name}.ko" \) 2>/dev/null | head -n 1 || true)"
    [ -n "${src}" ] || return 0
    case "${src}" in
        *.zst)
            command -v zstd >/dev/null 2>&1 || return 0
            zstd -d -f -q -o "${STAGING}/modules/${name}.ko" "${src}" 2>/dev/null || true
            ;;
        *)
            cp -a "${src}" "${STAGING}/modules/${name}.ko"
            ;;
    esac
}

KMOD_LIST=(
    netfs 9pnet 9pnet_virtio 9p overlay
    virtio virtio_ring virtio_pci virtio_net virtio_mmio
    inet_diag tcp_diag unix_diag af_packet_diag netlink_diag veth
    nfnetlink nf_tables x_tables nft_compat nft_chain_nat nft_nat nft_masq nft_ct nft_limit
    ip_tables iptable_filter iptable_nat iptable_mangle
    nf_defrag_ipv4 nf_defrag_ipv6 nf_conntrack nf_nat
    xt_nat xt_MASQUERADE xt_addrtype xt_conntrack
    llc stp bridge br_netfilter
)

if [ "${T9_KERNEL}" = host ]; then
    KMOD_VER="$(uname -r)"
    echo "T9_KERNEL=host: packing modules from /lib/modules/${KMOD_VER} (not git 6.17 .ko)"
    if [ ! -d "/lib/modules/${KMOD_VER}" ]; then
        echo "ERROR: /lib/modules/${KMOD_VER} missing"
        exit 1
    fi
    for name in "${KMOD_LIST[@]}"; do
        pack_kmod "${name}"
    done
else
    if [ -d "${SCRIPT_DIR}/modules" ]; then
        cp -a "${SCRIPT_DIR}/modules"/* "${STAGING}/modules/" 2>/dev/null || true
    fi
    BZ_KVER="$(file -b "${SCRIPT_DIR}/bzImage" 2>/dev/null | sed -n 's/.*version \([^ ]*\).*/\1/p' || true)"
    if [ -n "${BZ_KVER}" ] && [ -d "/lib/modules/${BZ_KVER}" ]; then
        KMOD_VER="${BZ_KVER}"
        echo "Packing extra modules from /lib/modules/${KMOD_VER} for pinned bzImage"
        for name in "${KMOD_LIST[@]}"; do
            pack_kmod "${name}"
        done
    else
        echo "Using checked-in appliance/modules (no /lib/modules/${BZ_KVER:-unknown})"
    fi
fi
chmod 644 "${STAGING}/modules/"* 2>/dev/null || true
echo "Installed $(ls -1 "${STAGING}/modules" 2>/dev/null | wc -l) modules to /modules/"

# 4. Copy host CRIU binary and dynamic dependencies
echo "[4/7] Packaging CRIU binary and libraries..."
CRIU_BIN="$(which criu 2>/dev/null || echo "/usr/sbin/criu")"
if [ -f "${CRIU_BIN}" ]; then
    cp -L "${CRIU_BIN}" "${STAGING}/usr/sbin/criu"
    cp -L "${CRIU_BIN}" "${STAGING}/sbin/criu"
    ln -sf /sbin/criu "${STAGING}/bin/criu"
    chmod 755 "${STAGING}/usr/sbin/criu" "${STAGING}/sbin/criu"

    mkdir -p "${STAGING}/lib/x86_64-linux-gnu" "${STAGING}/usr/lib/x86_64-linux-gnu" "${STAGING}/lib64"

    for bin_to_check in "${CRIU_BIN}" /bin/bash; do
        for lib in $(ldd "${bin_to_check}" 2>/dev/null | grep -o '/[^ ]*' || true); do
            if [ -f "${lib}" ]; then
                fname="$(basename "${lib}")"
                cp -L "${lib}" "${STAGING}/lib/x86_64-linux-gnu/${fname}" 2>/dev/null || true
                cp -L "${lib}" "${STAGING}/usr/lib/x86_64-linux-gnu/${fname}" 2>/dev/null || true
                if [[ "${lib}" == *ld-linux* ]]; then
                    cp -L "${lib}" "${STAGING}/lib64/${fname}" 2>/dev/null || true
                fi
            fi
        done
    done
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
    sudo apt-get install -y dropbear-bin >/dev/null
fi
DROPBEAR_BIN="$(command -v dropbear)"
DROPBEARKEY_BIN="$(command -v dropbearkey || true)"
if [ -z "${DROPBEAR_BIN}" ] || [ ! -f "${DROPBEAR_BIN}" ]; then
    echo "ERROR: dropbear not found (install dropbear-bin)"
    exit 1
fi
cp -L "${DROPBEAR_BIN}" "${STAGING}/usr/sbin/dropbear"
chmod 755 "${STAGING}/usr/sbin/dropbear"
for lib in $(ldd "${DROPBEAR_BIN}" 2>/dev/null | grep -o '/[^ ]*' || true); do
    if [ -f "${lib}" ]; then
        fname="$(basename "${lib}")"
        cp -L "${lib}" "${STAGING}/lib/x86_64-linux-gnu/${fname}" 2>/dev/null || true
        cp -L "${lib}" "${STAGING}/usr/lib/x86_64-linux-gnu/${fname}" 2>/dev/null || true
        if [[ "${lib}" == *ld-linux* ]]; then
            cp -L "${lib}" "${STAGING}/lib64/${fname}" 2>/dev/null || true
        fi
    fi
done
if [ -n "${DROPBEARKEY_BIN}" ] && [ -f "${DROPBEARKEY_BIN}" ]; then
    cp -L "${DROPBEARKEY_BIN}" "${STAGING}/usr/sbin/dropbearkey"
    chmod 755 "${STAGING}/usr/sbin/dropbearkey"
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
mkdir -p "${STAGING}/lib/x86_64-linux-gnu" "${STAGING}/usr/lib/x86_64-linux-gnu" "${STAGING}/lib64"
for bin_to_check in "${DROPBEAR_BIN}" ${DROPBEARKEY_BIN:-}; do
    [ -n "${bin_to_check}" ] && [ -f "${bin_to_check}" ] || continue
    for lib in $(ldd "${bin_to_check}" 2>/dev/null | grep -o '/[^ ]*' || true); do
        if [ -f "${lib}" ]; then
            fname="$(basename "${lib}")"
            cp -L "${lib}" "${STAGING}/lib/x86_64-linux-gnu/${fname}" 2>/dev/null || true
            cp -L "${lib}" "${STAGING}/usr/lib/x86_64-linux-gnu/${fname}" 2>/dev/null || true
            if [[ "${lib}" == *ld-linux* ]]; then
                cp -L "${lib}" "${STAGING}/lib64/${fname}" 2>/dev/null || true
            fi
        fi
    done
done

# Package official Ubuntu run-init binary and its klibc shared runtime
if [ -f /usr/lib/klibc/bin/run-init ]; then
    rm -f "${STAGING}/sbin/run-init"
    cp -a /usr/lib/klibc/bin/run-init "${STAGING}/sbin/run-init"
    chmod 755 "${STAGING}/sbin/run-init"
    mkdir -p "${STAGING}/usr/lib" "${STAGING}/lib"
    cp -a /usr/lib/klibc-*.so "${STAGING}/usr/lib/" 2>/dev/null || true
    cp -a /lib/klibc-*.so "${STAGING}/lib/" 2>/dev/null || true
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
        fname="$(basename "${found_lib}")"
        if [ -e "${found_lib}" ] && [ ! -e "${STAGING}/lib/x86_64-linux-gnu/${fname}" ]; then
            cp -L "${found_lib}" "${STAGING}/lib/x86_64-linux-gnu/${fname}" 2>/dev/null || true
            cp -L "${found_lib}" "${STAGING}/usr/lib/x86_64-linux-gnu/${fname}" 2>/dev/null || true
        fi
    done
done

# Ensure standard dynamic linker paths
if [ -f /lib64/ld-linux-x86-64.so.2 ]; then
    cp -L /lib64/ld-linux-x86-64.so.2 "${STAGING}/lib64/ld-linux-x86-64.so.2" 2>/dev/null || true
    cp -L /lib64/ld-linux-x86-64.so.2 "${STAGING}/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" 2>/dev/null || true
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


# Sudo configuration
mkdir -p "${STAGING}/etc/sudoers.d"
cat << 'EOF' > "${STAGING}/etc/sudoers"
Defaults	env_reset
Defaults	mail_badpass
Defaults	secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

root	ALL=(ALL:ALL) ALL
runner	ALL=(ALL:ALL) NOPASSWD: ALL
%admin	ALL=(ALL:ALL) ALL
%sudo	ALL=(ALL:ALL) NOPASSWD: ALL
EOF
chmod 0440 "${STAGING}/etc/sudoers" 2>/dev/null || true

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
EOF
if grep -E "^runner:" /etc/passwd >> "${STAGING}/etc/passwd" 2>/dev/null; then
    :
else
    echo "runner:x:1001:1001:runner:/home/runner:/bin/bash" >> "${STAGING}/etc/passwd"
fi
grep -E "^$(whoami):" /etc/passwd >> "${STAGING}/etc/passwd" 2>/dev/null || true

cat << 'EOF' > "${STAGING}/etc/group"
root:x:0:
EOF
if grep -E "^runner:" /etc/group >> "${STAGING}/etc/group" 2>/dev/null; then
    :
else
    echo "runner:x:1001:" >> "${STAGING}/etc/group"
fi
grep -E "^$(whoami):" /etc/group >> "${STAGING}/etc/group" 2>/dev/null || true
if grep -E "^docker:" /etc/group >> "${STAGING}/etc/group" 2>/dev/null; then
    :
else
    echo "docker:x:988:" >> "${STAGING}/etc/group"
fi

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

# Guest-safe /etc/fstab stub (avoids host block device wait stalls under systemd)
cat << 'EOF' > "${STAGING}/etc/fstab"
# /etc/fstab: MicroVM guest filesystem table (rootfs mounted by initramfs)
EOF

# Fresh machine-id for systemd-machine-id-setup
touch "${STAGING}/etc/machine-id"

# Shadow authentication file for guest accounts
cat << 'EOF' > "${STAGING}/etc/shadow"
root:*:19700:0:99999:7:::
runner:*:19700:0:99999:7:::
EOF
chmod 640 "${STAGING}/etc/shadow"

# Mask conflicting host services that would race Dropbear or unmanage network
mkdir -p "${STAGING}/etc/systemd/system" "${STAGING}/etc/systemd/network"
for svc in ssh.service ssh.socket sshd.service \
           walinuxagent.service cloud-init.service cloud-init-local.service \
           cloud-config.service cloud-final.service azure-setup.service \
           unattended-upgrades.service apt-daily.service apt-daily.timer \
           apt-daily-upgrade.service apt-daily-upgrade.timer \
           systemd-udev-settle.service \
           systemd-networkd.service systemd-networkd-wait-online.service \
           NetworkManager.service; do
    ln -sf /dev/null "${STAGING}/etc/systemd/system/${svc}"
done
ln -sf /usr/lib/systemd/system/multi-user.target "${STAGING}/etc/systemd/system/default.target"
cat << 'EOF' > "${STAGING}/etc/systemd/network/99-unmanaged-all.network"
[Match]
Name=eth* tap* lo

[Link]
Unmanaged=yes
EOF

# 6. Generate guest /init
echo "[6/7] Writing guest /init..."
cat << 'EOF' > "${STAGING}/init"
#!/bin/busybox sh
set +e

progress() {
    msg="$*"
    echo "[GUEST] ${msg}"
    # Checkpoint 9p moves to /newroot/mnt/checkpoint before Dropbear.
    for d in /newroot/mnt/checkpoint /mnt/checkpoint; do
        if [ -d "${d}" ]; then
            echo "${msg}" >> "${d}/guest_progress.txt" 2>/dev/null || true
        fi
    done
    /bin/busybox sync 2>/dev/null || true
}

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

# Ensure /etc/sudoers is owned by root (uid 0) with mode 0440
/bin/busybox chown 0:0 /etc/sudoers 2>/dev/null || true
/bin/busybox chown -R 0:0 /etc/sudoers.d 2>/dev/null || true
/bin/busybox chmod 0440 /etc/sudoers 2>/dev/null || true


# Set max pid limit
echo 4194304 > /proc/sys/kernel/pid_max 2>/dev/null || true

# Load diagnostic kernel modules, then iptables-nat/bridge for guest dockerd.
for mod in inet_diag tcp_diag unix_diag af_packet_diag netlink_diag veth nfnetlink nf_tables \
           x_tables nft_compat nft_chain_nat nft_nat nft_masq nft_ct nft_limit \
           ip_tables iptable_filter nf_defrag_ipv4 nf_defrag_ipv6 nf_conntrack nf_nat \
           iptable_nat xt_nat xt_MASQUERADE xt_addrtype xt_conntrack llc stp bridge br_netfilter; do

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

# Load virtio then 9p virtio filesystem modules and overlayfs in dependency order
for mod in virtio virtio_ring virtio_pci virtio_net virtio_mmio netfs 9pnet 9pnet_virtio 9p overlay; do
    if [ -f "/modules/${mod}.ko" ]; then
        if /bin/busybox insmod "/modules/${mod}.ko" 2>&1; then
            echo "[GUEST] [OK] Loaded module ${mod}"
        else
            echo "[GUEST] [FAIL] Failed to load 9p module ${mod}"
        fi
    else
        echo "[GUEST] [FAIL] module /modules/${mod}.ko not found!"
    fi
done

# Mount checkpoint first to read net_mode (Porter TAP vs user NAT).
/bin/busybox mkdir -p /mnt/checkpoint
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=none checkpoint /mnt/checkpoint 2>&1 \
    && echo "[GUEST] [OK] Mounted checkpoint share (early)" \
    || echo "[GUEST] [FAIL] Checkpoint share mount failed!"
progress "checkpoint 9p mounted"

NET_MODE="user"
if [ -f /mnt/checkpoint/net_mode.txt ]; then
    NET_MODE="$(/bin/busybox cat /mnt/checkpoint/net_mode.txt)"
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
echo "=== Hostname: $(/bin/busybox hostname)                 ==="
echo "=== Kernel:   $(/bin/busybox uname -r)                 ==="
echo "=== PID 1:    /bin/busybox sh /init                    ==="
echo "=========================================================="

# 1. Base rootfs tmpfs for systemd switch_root
/bin/busybox mkdir -p /newroot
/bin/busybox mount -t tmpfs -o mode=0755 tmpfs /newroot

# 2. Standard directory layout and merged-usr symlinks (/bin, /sbin, /lib, /lib64 -> usr/...)
/bin/busybox mkdir -p /newroot/usr /newroot/opt /newroot/etc /newroot/var /newroot/home /newroot/root \
                      /newroot/tmp /newroot/run /newroot/mnt /newroot/dev /newroot/proc /newroot/sys
/bin/busybox ln -sf usr/bin /newroot/bin
/bin/busybox ln -sf usr/sbin /newroot/sbin
/bin/busybox ln -sf usr/lib /newroot/lib
/bin/busybox ln -sf usr/lib64 /newroot/lib64

# 3. Mount 9p shares and OverlayFS into newroot
echo "[GUEST] Mounting 9p shares and overlays into /newroot..."
/bin/busybox mkdir -p /newroot/.overlay/lower_usr /newroot/.overlay/usr_upper /newroot/.overlay/usr_work
/bin/busybox mkdir -p /newroot/.overlay/lower_opt /newroot/.overlay/opt_upper /newroot/.overlay/opt_work

/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose,ro host_usr /newroot/.overlay/lower_usr 2>&1 \
    && echo "[GUEST] [OK] Mounted host_usr at /newroot/.overlay/lower_usr" \
    || echo "[GUEST] [FAIL] host_usr mount failed!"

/bin/busybox mount -t overlay overlay -o lowerdir=/newroot/.overlay/lower_usr,upperdir=/newroot/.overlay/usr_upper,workdir=/newroot/.overlay/usr_work /newroot/usr 2>&1 \
    && echo "[GUEST] [OK] Mounted overlayfs on /newroot/usr" \
    || echo "[GUEST] [FAIL] overlayfs on /newroot/usr failed!"

if /bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose,ro host_opt /newroot/.overlay/lower_opt 2>/dev/null; then
    echo "[GUEST] [OK] Mounted host_opt at /newroot/.overlay/lower_opt"
    /bin/busybox mount -t overlay overlay -o lowerdir=/newroot/.overlay/lower_opt,upperdir=/newroot/.overlay/opt_upper,workdir=/newroot/.overlay/opt_work /newroot/opt 2>&1 \
        && echo "[GUEST] [OK] Mounted overlayfs on /newroot/opt" \
        || echo "[GUEST] [FAIL] overlayfs on /newroot/opt failed!"
fi

/bin/busybox mkdir -p /newroot/home/runner
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose host_runner /newroot/home/runner 2>&1 \
    && echo "[GUEST] [OK] Mounted host_runner share" \
    || echo "[GUEST] [FAIL] host_runner mount failed!"

if [ -d /newroot/usr/share/dotnet ]; then
    /bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose dotnet /newroot/usr/share/dotnet 2>/dev/null || true
fi

# Move checkpoint share from initramfs to newroot
/bin/busybox mkdir -p /newroot/mnt/checkpoint
if /bin/busybox mount --move /mnt/checkpoint /newroot/mnt/checkpoint 2>/dev/null; then
    echo "[GUEST] [OK] Moved checkpoint share to /newroot/mnt/checkpoint"
else
    /bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=none checkpoint /newroot/mnt/checkpoint 2>&1 \
        && echo "[GUEST] [OK] Mounted checkpoint share in /newroot" \
        || echo "[GUEST] [FAIL] checkpoint mount in /newroot failed"
fi

# 4. Guest-private /etc: copy initramfs stubs, then an allowlist from a
#    temporary read-only host_etc 9p. Unmount before switch_root so /etc is
#    never a live host share (unlike /usr|/opt overlays).
echo "[GUEST] Seeding guest-private /etc from initramfs..."
/bin/busybox cp -a /etc/. /newroot/etc/ 2>/dev/null || true

echo "[GUEST] Copying host /etc allowlist (tooling only), then unmounting..."
/bin/busybox mkdir -p /mnt/host_etc
if /bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose,ro host_etc /mnt/host_etc 2>/dev/null; then
    echo "[GUEST] [OK] Mounted host_etc (temporary, copy-only)"
    for item in alternatives ssl ca-certificates \
                ld.so.cache ld.so.conf ld.so.conf.d \
                apt pam.d security \
                nsswitch.conf os-release environment mime.types magic \
                apparmor apparmor.d; do
        if [ -e "/mnt/host_etc/${item}" ]; then
            /bin/busybox rm -rf "/newroot/etc/${item}" 2>/dev/null || true
            /bin/busybox cp -a "/mnt/host_etc/${item}" "/newroot/etc/${item}" 2>/dev/null \
                && echo "[GUEST] [OK] copied /etc/${item}" \
                || echo "[GUEST] [WARN] copy /etc/${item} failed"
        fi
    done
    /bin/busybox umount /mnt/host_etc 2>/dev/null \
        && echo "[GUEST] [OK] Unmounted host_etc (no live /etc share)" \
        || echo "[GUEST] [WARN] host_etc umount failed"
else
    echo "[GUEST] [WARN] host_etc 9p unavailable; using initramfs /etc only"
fi
/bin/busybox rmdir /mnt/host_etc 2>/dev/null || true

# Guest dockerd needs its own graph dir and a daemon.json without host "hosts".
/bin/busybox mkdir -p /newroot/var/lib/docker /newroot/var/lib/containerd /newroot/etc/docker
cat << 'DOCKEREOF' > /newroot/etc/docker/daemon.json
{
  "storage-driver": "overlay2",
  "live-restore": false,
  "iptables": true,
  "ip6tables": false
}
DOCKEREOF

# Placeholder /var only — dpkg copy is a later step after 3-step is green again.
/bin/busybox mkdir -p /newroot/var/run /newroot/var/lock /newroot/var/tmp /newroot/var/log \
    /newroot/var/cache/apt/archives/partial /newroot/var/lib/apt/lists/partial
/bin/busybox chmod 1777 /newroot/var/tmp 2>/dev/null || true

# Guest identity — never imported from host /etc
cat << 'FSTABEOF' > /newroot/etc/fstab
# /etc/fstab: MicroVM guest filesystem table (rootfs mounted by initramfs)
FSTABEOF

: > /newroot/etc/machine-id
echo "qemu-restore-vm" > /newroot/etc/hostname
rm -f /newroot/etc/ssh/ssh_host_* 2>/dev/null || true
/bin/busybox rm -rf /newroot/etc/systemd/system/multi-user.target.wants 2>/dev/null || true
/bin/busybox rm -rf /newroot/etc/systemd/system/default.target.wants 2>/dev/null || true
/bin/busybox rm -rf /newroot/etc/systemd/system/timers.target.wants 2>/dev/null || true
/bin/busybox rm -rf /newroot/etc/systemd/system/sockets.target.wants 2>/dev/null || true
# Initramfs /etc may still carry host snapd mask links; snap state is copied when under cap.
for svc in snapd.service snapd.socket snapd.seeded.service; do
    /bin/busybox rm -f "/newroot/etc/systemd/system/${svc}"
done

# Ensure /usr/local is writable for workflow tools
/bin/busybox chmod 1777 /newroot/usr/local/bin /newroot/usr/local 2>/dev/null || true

# Systemd target and service masking on guest overlay
/bin/busybox mkdir -p /newroot/etc/systemd/system /newroot/etc/systemd/network
for svc in ssh.service ssh.socket sshd.service \
           walinuxagent.service cloud-init.service cloud-init-local.service \
           cloud-config.service cloud-final.service azure-setup.service \
           unattended-upgrades.service apt-daily.service apt-daily.timer \
           apt-daily-upgrade.service apt-daily-upgrade.timer \
           systemd-udev-settle.service apparmor.service \
           systemd-networkd.service systemd-networkd-wait-online.service \
           NetworkManager.service; do
    /bin/busybox ln -sf /dev/null "/newroot/etc/systemd/system/${svc}"
done
if [ -f /newroot/lib/systemd/system/multi-user.target ]; then
    /bin/busybox ln -sf /lib/systemd/system/multi-user.target /newroot/etc/systemd/system/default.target 2>/dev/null || true
elif [ -f /newroot/usr/lib/systemd/system/multi-user.target ]; then
    /bin/busybox ln -sf /usr/lib/systemd/system/multi-user.target /newroot/etc/systemd/system/default.target 2>/dev/null || true
fi
cat << 'RESOLVEOF' > /newroot/etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 168.63.129.16
RESOLVEOF
/bin/busybox chmod 644 /newroot/etc/resolv.conf 2>/dev/null || true

cat << 'NETEOF' > /newroot/etc/systemd/network/99-unmanaged-all.network
[Match]
Name=eth* tap* lo

[Link]
Unmanaged=yes
NETEOF

# Copy Dropbear host keys and config from initramfs to /newroot/etc/dropbear/
/bin/busybox mkdir -p /newroot/etc/dropbear
/bin/busybox cp -a /etc/dropbear/* /newroot/etc/dropbear/ 2>/dev/null || true
/bin/busybox chown -R 0:0 /newroot/etc/dropbear 2>/dev/null || true
/bin/busybox chmod 700 /newroot/etc/dropbear 2>/dev/null || true

# Sudo configuration for runner and root
/bin/busybox mkdir -p /newroot/etc/sudoers.d
cat << 'SUDOEOF' > /newroot/etc/sudoers.d/99-runner-nopasswd
runner ALL=(ALL:ALL) NOPASSWD: ALL
root ALL=(ALL:ALL) ALL
SUDOEOF
/bin/busybox chmod 0440 /newroot/etc/sudoers.d/99-runner-nopasswd 2>/dev/null || true
/bin/busybox chown -R 0:0 /newroot/etc/sudoers.d 2>/dev/null || true

# Pre-populate VM markers on /newroot/etc/is_vm
/bin/busybox touch /newroot/etc/is_vm
/bin/busybox echo "is_vm" > /newroot/etc/is_vm
/bin/busybox chmod 666 /newroot/etc/is_vm

# 5. Root & Dropbear auth setup in /newroot
/bin/busybox mkdir -p /newroot/root/.ssh /newroot/etc/dropbear /newroot/var/run /newroot/var/log
/bin/busybox chown -R 0:0 /newroot/root /newroot/etc/dropbear 2>/dev/null || true
/bin/busybox chmod 755 /newroot/root
/bin/busybox chmod 700 /newroot/root/.ssh
/bin/busybox cp -a /root/.ssh/* /newroot/root/.ssh/ 2>/dev/null || true
/bin/busybox chmod 600 /newroot/root/.ssh/authorized_keys 2>/dev/null || true
/bin/busybox cp -a /etc/dropbear/* /newroot/etc/dropbear/ 2>/dev/null || true

# Copy Dropbear binary, BusyBox, and restore script into newroot
/bin/busybox cp -a /usr/sbin/dropbear /newroot/usr/sbin/dropbear 2>/dev/null || true
/bin/busybox chmod 755 /newroot/usr/sbin/dropbear 2>/dev/null || true
/bin/busybox cp -a /usr/sbin/t9_restore.sh /newroot/t9_restore.sh 2>/dev/null || true
/bin/busybox chmod 755 /newroot/t9_restore.sh 2>/dev/null || true
/bin/busybox cp -a /bin/busybox /newroot/bin/busybox 2>/dev/null || true
/bin/busybox chmod 755 /newroot/bin/busybox 2>/dev/null || true
/bin/busybox mkdir -p /newroot/modules
/bin/busybox cp -a /modules/*.ko /newroot/modules/ 2>/dev/null || true

if [ -f /opt_sudo_shim ]; then
    /bin/busybox cp -a /opt_sudo_shim /newroot/opt_sudo_shim 2>/dev/null || true
    /bin/busybox chmod 4755 /newroot/opt_sudo_shim 2>/dev/null || true
fi

for candidate in /usr/sbin/criu /sbin/criu /usr/local/sbin/criu; do
    if [ -f "$candidate" ]; then
        /bin/busybox cp -a "$candidate" /newroot/usr/sbin/criu 2>/dev/null || true
        /bin/busybox cp -a "$candidate" /newroot/usr/local/sbin/criu 2>/dev/null || true
        /bin/busybox chmod 755 /newroot/usr/sbin/criu /newroot/usr/local/sbin/criu 2>/dev/null || true
        break
    fi
done

# 6. Mount pristine virtual kernel filesystems in /newroot
/bin/busybox mount -t proc proc /newroot/proc 2>/dev/null || true
/bin/busybox mount -t sysfs sysfs /newroot/sys 2>/dev/null || true
/bin/busybox mount -t devtmpfs devtmpfs /newroot/dev 2>/dev/null || true
/bin/busybox mount -t tmpfs -o mode=0755 tmpfs /newroot/run 2>/dev/null || true
/bin/busybox mount -t tmpfs -o mode=1777 tmpfs /newroot/tmp 2>/dev/null || true
/bin/busybox mkdir -p /newroot/dev/pts /newroot/dev/shm
/bin/busybox mount -t devpts devpts /newroot/dev/pts 2>/dev/null || true
/bin/busybox mount -t tmpfs tmpfs /newroot/dev/shm 2>/dev/null || true
if [ -d /newroot/mnt/checkpoint/dev_shm ]; then
    echo "[GUEST] Restoring /dev/shm from host..."
    /bin/busybox cp -a /newroot/mnt/checkpoint/dev_shm/* /newroot/dev/shm/ 2>/dev/null || true
    /bin/busybox chmod 1777 /newroot/dev/shm
fi

# 7. Checkpoint images and VM marker staging (populated in /run/restore only)
/bin/busybox mkdir -p /newroot/run/restore
/bin/busybox cp -a /newroot/mnt/checkpoint/*.img /newroot/mnt/checkpoint/*.txt /newroot/run/restore/ 2>/dev/null || true
/bin/busybox chmod -R 777 /newroot/run/restore 2>/dev/null || true
/bin/busybox touch /newroot/run/is_vm
/bin/busybox echo "is_vm" > /newroot/run/is_vm
/bin/busybox ln -sf /mnt/checkpoint /newroot/run/runner_checkpoint 2>/dev/null || true

# 8. Start early Dropbear SSH server directly before switch_root
echo "[GUEST] Starting early Dropbear SSH server..."
/bin/busybox chroot /newroot /usr/sbin/dropbear -R -E -s -p 22 2>&1 || /usr/sbin/dropbear -R -E -s -p 22 2>&1 || echo "[GUEST] [FAIL] dropbear start failed"
progress "dropbear started"
echo SSH_READY
echo "[GUEST] SSH_READY — Dropbear listening on port 22 before systemd handoff"
progress "SSH_READY"

# 9. Unmount temporary filesystems in early initramfs
/bin/busybox umount /dev/pts /dev/shm /tmp /mnt/checkpoint /mnt 2>/dev/null || true
/bin/busybox umount /sys /proc /dev 2>/dev/null || true

# 10. Switch root and hand off PID 1 to systemd via run-init
echo "[GUEST] Switching root to systemd PID 1 via run-init..."
if [ -x /sbin/run-init ]; then
    exec /sbin/run-init -p -c /dev/console /newroot /sbin/init
fi
exec /bin/busybox switch_root /newroot /sbin/init
echo "[GUEST] [FATAL] switch_root returned: $?"
EOF
chmod 755 "${STAGING}/init"

cat << 'RESTOREEOF' > "${STAGING}/usr/sbin/t9_restore.sh"
#!/bin/busybox sh
# Run from SSH after appliance boot. Does not dump; only restore.
set +e
if [ -f /mnt/checkpoint/state.txt ]; then
    echo "t9_restore start" >> /mnt/checkpoint/guest_progress.txt
fi
# Shared 9p flag: restored host-namespace tasks cannot see guest /tmp|/run|/mnt
# but they can still read the original checkpoint dir (same files as migrator_ok).
echo "guest_restore_ok" > /mnt/checkpoint/guest_restore_ok 2>/dev/null || true
/bin/busybox chmod a+rw /mnt/checkpoint/guest_restore_ok 2>/dev/null || true
RESTORE_DIR="/run/restore"
if [ ! -f "${RESTORE_DIR}/inventory.img" ]; then
    echo "[GUEST] t9_restore: copying images from /mnt/checkpoint to /run/restore"
    mkdir -p /run/restore
    cp -a /mnt/checkpoint/*.img /mnt/checkpoint/*.txt /run/restore/ 2>/dev/null || true
    chmod -R 777 /run/restore 2>/dev/null || true
else
    echo "[GUEST] t9_restore: images already present in /run/restore (skipping redundant copy)"
fi
chmod 755 / 2>/dev/null || true
echo "[GUEST] Marking VM environment for restored processes"
/bin/busybox touch /run/is_vm /etc/is_vm /tmp/is_vm 2>/dev/null || true
/bin/busybox echo "is_vm" | /bin/busybox tee /run/is_vm /etc/is_vm /tmp/is_vm 2>/dev/null || true
/bin/busybox chmod 666 /run/is_vm /etc/is_vm /tmp/is_vm 2>/dev/null || true
/bin/busybox ln -sfn /mnt/checkpoint /run/runner_checkpoint 2>/dev/null || true
echo "is_vm marker created" >> /mnt/checkpoint/guest_progress.txt 2>/dev/null || true
# /usr and /opt are already the host trees via 9p+overlay from /init.
# Do not bind-mount host_usr over them — that hid the overlay and guest writes.
echo "[GUEST] Skipping host /usr bind; overlay remains in place"
echo "host_rootfs_bind skipped overlay_ok" >> /mnt/checkpoint/guest_progress.txt 2>/dev/null || true


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

echo "[GUEST] Seeding guest /var (COPY set) and host passwd/group before CRIU..."
echo "apt_seed_start" >> /mnt/checkpoint/guest_progress.txt 2>/dev/null || true
/bin/busybox mkdir -p /var/lib /mnt/host_etc
if [ -f /mnt/checkpoint/var_seed.tar ]; then
    /bin/busybox tar -xf /mnt/checkpoint/var_seed.tar -C / \
        && echo "[GUEST] [OK] extracted /mnt/checkpoint/var_seed.tar" \
        || echo "[GUEST] [WARN] var_seed.tar extract failed"
else
    echo "[GUEST] [WARN] var_seed.tar missing"
fi
if /bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose,ro host_etc /mnt/host_etc 2>/dev/null; then
    # Host dpkg statoverrides name users like _chrony; keep guest root's shell.
    for item in passwd group shadow gshadow; do
        if [ -f "/mnt/host_etc/${item}" ]; then
            /bin/busybox cp -a "/mnt/host_etc/${item}" "/etc/${item}" \
                && echo "[GUEST] [OK] copied /etc/${item}" || true
        fi
    done
    /bin/busybox sed -i 's|^root:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:.*|root:x:0:0:root:/root:/bin/sh|' /etc/passwd 2>/dev/null || true
    /bin/busybox umount /mnt/host_etc 2>/dev/null || true
fi
echo "apt_seed_done" >> /mnt/checkpoint/guest_progress.txt 2>/dev/null || true

TCP_FLAG="--tcp-close"
if [ -f /mnt/checkpoint/criu_tcp_mode.txt ]; then
    case "$(/bin/busybox cat /mnt/checkpoint/criu_tcp_mode.txt)" in
        close) TCP_FLAG="--tcp-close" ;;
        established) TCP_FLAG="--tcp-established" ;;
    esac
fi
echo "[GUEST] t9_restore: criu restore ${TCP_FLAG}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
CRIU_BIN=""
for candidate in /usr/local/sbin/criu /usr/sbin/criu /sbin/criu /bin/criu; do
    if [ -x "$candidate" ]; then CRIU_BIN="$candidate"; break; fi
done
[ -n "$CRIU_BIN" ] || CRIU_BIN="$(command -v criu || echo /usr/sbin/criu)"
echo "[GUEST] Using CRIU binary: ${CRIU_BIN} with restore directory: ${RESTORE_DIR}"
"${CRIU_BIN}" restore -d -D "${RESTORE_DIR}" \
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
echo "is_vm=$(/bin/busybox cat /run/is_vm 2>/dev/null || /bin/busybox cat /tmp/is_vm 2>/dev/null || echo missing)" >> "${DIAG}"

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
/bin/busybox touch /run/is_vm /etc/is_vm /tmp/is_vm 2>/dev/null || true
/bin/busybox echo "is_vm" | /bin/busybox tee /run/is_vm /etc/is_vm /tmp/is_vm 2>/dev/null || true
/bin/busybox chmod 666 /run/is_vm /etc/is_vm /tmp/is_vm 2>/dev/null || true
/bin/busybox ln -sfn /mnt/checkpoint /run/runner_checkpoint 2>/dev/null || true

echo "--- process scan ---" >> "${DIAG}"
/bin/busybox ps 2>/dev/null | /bin/busybox head -n 30 >> "${DIAG}" || true
for pid in $(/bin/busybox ls /proc 2>/dev/null | /bin/busybox grep -E '^[0-9]+$'); do
    cmd="$(/bin/busybox tr '\0' ' ' < /proc/${pid}/cmdline 2>/dev/null || true)"
    echo "${cmd}" | /bin/busybox grep -qE 'Runner\.(Worker|Listener)|is_vm_wait' || continue
    state="$(/bin/busybox awk '/^State:/ {print $2; exit}' /proc/${pid}/status 2>/dev/null || true)"
    echo "pid=${pid} state=${state} cmd=${cmd}" >> "${DIAG}"
    /bin/busybox ls -la "/proc/${pid}/fd" 2>/dev/null | /bin/busybox head -n 15 >> "${DIAG}" || true
    # Restored tasks keep the dumped host mount/UTS ns, so guest /run /tmp
    # markers are invisible to them. Write into each restored ns directly.
    ROOT="/proc/${pid}/root"
    /bin/busybox mkdir -p "${ROOT}/run" "${ROOT}/tmp" "${ROOT}/mnt/checkpoint" 2>/dev/null || true
    /bin/busybox echo "is_vm" | /bin/busybox tee "${ROOT}/run/is_vm" "${ROOT}/tmp/is_vm" "${ROOT}/etc/is_vm" >/dev/null 2>&1 || true
    /bin/busybox chmod 666 "${ROOT}/run/is_vm" "${ROOT}/tmp/is_vm" "${ROOT}/etc/is_vm" 2>/dev/null || true
    /bin/busybox ln -sfn /mnt/checkpoint "${ROOT}/run/runner_checkpoint" 2>/dev/null || true
    /bin/busybox mount --bind /mnt/checkpoint "${ROOT}/mnt/checkpoint" 2>/dev/null \
        && echo "bind_checkpoint pid=${pid} ok" >> "${DIAG}" \
        || echo "bind_checkpoint pid=${pid} skip" >> "${DIAG}"
    /bin/busybox nsenter -t "${pid}" -u /bin/busybox hostname qemu-restore-vm 2>/dev/null \
        && echo "uts_hostname pid=${pid} ok" >> "${DIAG}" \
        || echo "uts_hostname pid=${pid} skip" >> "${DIAG}"
done
echo "post_restore_diag written" >> /mnt/checkpoint/guest_progress.txt 2>/dev/null || true

echo "[GUEST] Starting snapd after CRIU restore..."
if [ -d /var/lib/snapd ] && [ -x /usr/bin/systemctl ]; then
    /usr/bin/systemctl unmask snapd.socket snapd.service snapd.seeded.service 2>>"${DIAG}" || true
    /usr/bin/systemctl start snapd.socket snapd.service 2>>"${DIAG}" \
        && echo "[GUEST] [OK] snapd start" \
        || echo "[GUEST] [WARN] snapd start failed"
    echo "snapd_start" >> /mnt/checkpoint/guest_progress.txt 2>/dev/null || true
fi

echo "[GUEST] Importing host systemd wants (denylist skip) after restore..."
/bin/busybox mkdir -p /mnt/host_etc /etc/systemd/system
if /bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000,cache=loose,ro host_etc /mnt/host_etc 2>/dev/null; then
    t9_skip_unit() {
        case "$1" in
            ssh.service|ssh.socket|sshd.service|sshd.socket)
                return 0 ;;
            walinuxagent.service|cloud-init.service|cloud-init-local.service|cloud-config.service|cloud-final.service|azure-setup.service)
                return 0 ;;
            systemd-networkd.service|systemd-networkd-wait-online.service|NetworkManager.service|systemd-udev-settle.service)
                return 0 ;;
            docker.service|docker.socket)
                return 0 ;;
        esac
        return 1
    }
    for wants in multi-user.target.wants sockets.target.wants timers.target.wants default.target.wants; do
        src="/mnt/host_etc/systemd/system/${wants}"
        dst="/etc/systemd/system/${wants}"
        [ -d "${src}" ] || continue
        /bin/busybox mkdir -p "${dst}"
        for link in "${src}"/*; do
            [ -e "${link}" ] || continue
            unit="$(/bin/busybox basename "${link}")"
            if t9_skip_unit "${unit}"; then
                echo "[GUEST] skip want ${unit}"
                continue
            fi
            /bin/busybox rm -f "${dst}/${unit}"
            /bin/busybox cp -a "${link}" "${dst}/${unit}" 2>/dev/null \
                && echo "[GUEST] [OK] want ${wants}/${unit}" || true
        done
    done
    /bin/busybox umount /mnt/host_etc 2>/dev/null || true
    if [ -x /usr/bin/systemctl ]; then
        /usr/bin/systemctl daemon-reload 2>>"${DIAG}" || true
        for wants in multi-user.target.wants sockets.target.wants; do
            dst="/etc/systemd/system/${wants}"
            [ -d "${dst}" ] || continue
            for link in "${dst}"/*; do
                [ -e "${link}" ] || continue
                unit="$(/bin/busybox basename "${link}")"
                t9_skip_unit "${unit}" && continue
                /usr/bin/systemctl unmask "${unit}" 2>>"${DIAG}" || true
                /usr/bin/systemctl start "${unit}" 2>>"${DIAG}" \
                    && echo "[GUEST] [OK] started ${unit}" \
                    || echo "[GUEST] [WARN] start ${unit} failed"
            done
        done
    fi
    echo "wants_imported" >> /mnt/checkpoint/guest_progress.txt 2>/dev/null || true
fi

echo "[GUEST] Starting guest dockerd (own socket; not host engine)..."
/bin/busybox mkdir -p /var/lib/docker /var/lib/containerd /run /var/run /etc/docker
if ! /bin/busybox grep -q '^docker:' /etc/group 2>/dev/null; then
    echo "docker:x:988:" >> /etc/group
    echo "[GUEST] added docker group" >>"${DIAG}"
fi
if [ ! -f /etc/docker/daemon.json ]; then
    echo '{"storage-driver":"overlay2","live-restore":false,"iptables":true,"ip6tables":false}' > /etc/docker/daemon.json
fi
if [ -x /sbin/apparmor_parser ] || [ -x /usr/sbin/apparmor_parser ]; then
    APPP=/usr/sbin/apparmor_parser
    [ -x /sbin/apparmor_parser ] && APPP=/sbin/apparmor_parser
    for prof in /etc/apparmor.d/docker /etc/apparmor.d/docker-default /etc/apparmor.d/usr.sbin.dockerd; do
        [ -f "${prof}" ] && "${APPP}" -r "${prof}" 2>>"${DIAG}" || true
    done
fi
if [ -x /usr/sbin/iptables-legacy ]; then
    echo "[GUEST] using iptables-legacy (nft CHAIN_ADD PREROUTING fails in this VM)"
    /usr/bin/update-alternatives --set iptables /usr/sbin/iptables-legacy 2>>"${DIAG}" || \
        /bin/busybox ln -sfn iptables-legacy /usr/sbin/iptables
    /usr/bin/update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>>"${DIAG}" || true
fi
    MP=/usr/sbin/modprobe
    [ -x /sbin/modprobe ] && MP=/sbin/modprobe
    for mod in overlay iptable_nat br_netfilter xt_MASQUERADE xt_conntrack xt_addrtype nft_compat; do
        "${MP}" "${mod}" 2>>"${DIAG}" || true
    done
fi
for mod in nft_compat xt_addrtype iptable_nat xt_MASQUERADE br_netfilter; do
    [ -f "/modules/${mod}.ko" ] || continue
    /bin/busybox insmod "/modules/${mod}.ko" 2>>"${DIAG}" || true
done
if [ -x /usr/bin/systemctl ]; then
    /usr/bin/systemctl unmask containerd.service docker.socket docker.service 2>>"${DIAG}" || true
    /usr/bin/systemctl reset-failed docker.service docker.socket 2>>"${DIAG}" || true
    /usr/bin/systemctl start containerd.service 2>>"${DIAG}" || true
    /usr/bin/systemctl start docker.socket docker.service 2>>"${DIAG}" \
        && echo "[GUEST] [OK] guest docker start" \
        || echo "[GUEST] [WARN] guest docker start failed"
fi
WAIT_DOCK=0
while [ "${WAIT_DOCK}" -lt 25 ]; do
    if [ -x /usr/bin/systemctl ] && /usr/bin/systemctl is-active --quiet docker.service 2>/dev/null; then
        break
    fi
    /bin/busybox sleep 1
    WAIT_DOCK=$((WAIT_DOCK + 1))
done
if [ -x /usr/bin/journalctl ]; then
    echo "--- docker journal ---" >>"${DIAG}"
    /usr/bin/journalctl -u docker -u containerd -n 80 --no-pager >>"${DIAG}" 2>/dev/null || true
fi
GUEST_DOCK=""
[ -S /run/docker.sock ] && GUEST_DOCK=/run/docker.sock
[ -z "${GUEST_DOCK}" ] && [ -S /var/run/docker.sock ] && GUEST_DOCK=/var/run/docker.sock
if [ -n "${GUEST_DOCK}" ]; then
    echo "[GUEST] [OK] guest docker.sock ${GUEST_DOCK} after ${WAIT_DOCK}s" >>"${DIAG}"
    for pid in $(/bin/busybox ls /proc 2>/dev/null | /bin/busybox grep -E '^[0-9]+$'); do
        cmd="$(/bin/busybox tr '\0' ' ' < /proc/${pid}/cmdline 2>/dev/null || true)"
        echo "${cmd}" | /bin/busybox grep -qE 'Runner\.(Worker|Listener)|is_vm_wait' || continue
        ROOT="/proc/${pid}/root"
        for dest in "${ROOT}/run/docker.sock" "${ROOT}/var/run/docker.sock"; do
            /bin/busybox mkdir -p "$(/bin/busybox dirname "${dest}")" 2>/dev/null || true
            /bin/busybox touch "${dest}" 2>/dev/null || true
            /bin/busybox mount --bind "${GUEST_DOCK}" "${dest}" 2>/dev/null \
                && echo "bind_guest_docker_sock pid=${pid} ${dest} ok" >>"${DIAG}" \
                || echo "bind_guest_docker_sock pid=${pid} ${dest} skip" >>"${DIAG}"
        done
    done
    echo "docker_guest_start" >> /mnt/checkpoint/guest_progress.txt 2>/dev/null || true
else
    echo "[GUEST] [WARN] guest docker.sock never appeared" >>"${DIAG}"
fi

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
