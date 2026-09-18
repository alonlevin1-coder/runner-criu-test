#!/usr/bin/env bash
# Inventory host /var and classify each entry.
# Policy: COPY apt/dpkg, size-gated snap, and small helper dbs; DROP the rest.
set -u

OUT="${1:-}"
QEMU_MEM="${QEMU_MEM:-4096}"
SNAP_COPY_MAX_BYTES="${SNAP_COPY_MAX_BYTES:-536870912}"
if [ -n "${OUT}" ]; then
    COPY_LIST="${COPY_LIST:-$(dirname "${OUT}")/var_copy.list}"
else
    COPY_LIST="${COPY_LIST:-/dev/null}"
fi
if [ "${COPY_LIST}" != /dev/null ]; then
    : > "${COPY_LIST}"
fi

fmt() {
    awk -v n="${1:-0}" 'BEGIN {
        if (n >= 1073741824) printf "%.1f GiB", n/1073741824
        else if (n >= 1048576) printf "%.1f MiB", n/1048576
        else if (n >= 1024) printf "%.1f KiB", n/1024
        else printf "%d B", n
    }'
}

dir_bytes() {
    local p="$1" n
    n="$(du -sb -x "${p}" 2>/dev/null | awk '{print $1}')"
    echo "${n:-0}"
}

# Classify a path relative to /var (lib/docker, cache/debconf, run, ...).
classify() {
    local rel="$1"
    case "${rel}" in
        lib)
            echo "SKIP container: see /var/lib children" ;;
        cache)
            echo "SKIP container: see /var/cache children" ;;
        run|lock|run/*|lock/*)
            echo "DROP runtime: guest tmpfs; host pid/socks would fight systemd" ;;
        lib/systemd|lib/dbus|lib/private|lib/NetworkManager)
            echo "DROP runtime: host systemd/dbus/NM machine state" ;;
        lib/docker|lib/containerd|lib/buildkit|lib/nerdctl|lib/cni|lib/kubelet)
            echo "DROP size+runtime: container images/state; use docker.sock if needed" ;;
        lib/snapd|snap|lib/snapd/*)
            echo "SNAP size-gated" ;;
        lib/lxc*|lib/lxd|lib/libvirt|lib/qemu)
            echo "DROP runtime: other hypervisors/containers" ;;
        lib/waagent|lib/azure|lib/cloud|lib/hyperv|lib/landscape)
            echo "DROP host-agent: Azure/cloud-init; units are masked" ;;
        cache/debconf)
            echo "COPY small: dpkg package configuration database" ;;
        cache|cache/apt|cache/snapd|cache/man|cache/fontconfig|cache/*)
            echo "DROP cache: regenerable; apt can refetch" ;;
        log|tmp|crash|spool|mail|spool/*)
            echo "DROP junk: logs/tmp/mail; not tool install state" ;;
        lib/dpkg|lib/apt)
            echo "COPY required: apt/dpkg database" ;;
        lib/ucf|lib/xml-core|lib/pam|lib/dictionaries-common|lib/command-not-found|lib/man-db)
            echo "COPY small: package helper dbs" ;;
        lib/gems|lib/mecab)
            echo "DROP size: language models; not needed for apt/snap/systemd" ;;
        lib/dkms|lib/usbutils|lib/ieee-data|lib/aspell|lib/ghostscript)
            echo "COPY small: language/firmware helper dbs" ;;
        lib/fwupd|lib/PackageKit|lib/update-notifier|lib/unattended-upgrades|lib/ubuntu-advantage|lib/ubuntu-release-upgrader)
            echo "COPY small: updater metadata" ;;
        lib/sudo|lib/polkit-1|lib/misc|lib/logrotate|lib/alsa|lib/plymouth|lib/colord)
            echo "COPY small: os helper state" ;;
        lib/grub|lib/shim|lib/shim-signed|lib/initramfs-tools|lib/os-prober)
            echo "DROP boot: not used after switch_root" ;;
        lib/apport)
            echo "DROP junk: crash reports" ;;
        backups)
            echo "COPY small: dpkg backups" ;;
        local|opt|www|metrics)
            echo "COPY if present: site-local tool state" ;;
        *)
            echo "DROP default: unknown host state; guest can recreate" ;;
    esac
}

emit() {
    local action="$1" bytes="$2" path="$3" why="$4"
    printf '%-10s %-10s %-36s %s\n' "${action}" "$(fmt "${bytes}")" "${path}" "${why}"
    if [ "${action}" = "COPY" ] && [ -e "${path}" ] && [ "${COPY_LIST}" != /dev/null ]; then
        printf '%s\n' "${path#/}" >> "${COPY_LIST}"
    fi
}

needs_bytes() {
    local rel="$1" why="$2"
    case "${rel}" in
        snap|lib/snapd) return 0 ;;
    esac
    case "${why%% *}" in
        COPY) return 0 ;;
        *) return 1 ;;
    esac
}

scan_one() {
    local p="$1" rel="$2"
    local bytes=0 why action gate
    if [ -L "${p}" ]; then
        why="runtime: symlink -> $(readlink "${p}" 2>/dev/null || true)"
        action="DROP"
        emit "${action}" 0 "${p}" "${why}"
        return
    fi
    why="$(classify "${rel}")"
    if needs_bytes "${rel}" "${why}"; then
        bytes="$(dir_bytes "${p}")"
        gate="$(size_gate_snap "${rel}" "${bytes}")"
        if [ -n "${gate}" ]; then
            why="${gate}"
        fi
    fi
    action="${why%% *}"
    why="${why#* }"
    total=$((total + bytes))
    if [ "${action}" = "COPY" ]; then
        copy_bytes=$((copy_bytes + bytes))
    elif [ "${action}" = "DROP" ]; then
        drop_bytes=$((drop_bytes + bytes))
    fi
    emit "${action}" "${bytes}" "${p}" "${why}"
}

# COPY snapd//var/snap only when small enough for guest tmpfs (GH ~240MiB; this
# dev box is multi-GiB and must stay DROP).
size_gate_snap() {
    local rel="$1" bytes="$2"
    case "${rel}" in
        snap|lib/snapd)
            if [ "${bytes}" -le "${SNAP_COPY_MAX_BYTES}" ]; then
                echo "COPY snap under cap $(fmt "${bytes}") <= $(fmt "${SNAP_COPY_MAX_BYTES}")"
            else
                echo "DROP snap over cap $(fmt "${bytes}") > $(fmt "${SNAP_COPY_MAX_BYTES}")"
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

{
    echo "=== host /var map $(date -u +%Y-%m-%dT%H:%M:%SZ) host=$(hostname) ==="
    echo "Guest /var is tmpfs inside QEMU_MEM=${QEMU_MEM} MB. Copying multi-GiB trees will OOM."
    echo "Policy: COPY apt/dpkg/snap(if small)+small helper dbs; DROP the rest."
    echo
    printf '%-10s %-10s %-36s %s\n' "ACTION" "SIZE" "PATH" "WHY"
    printf '%s\n' "--------------------------------------------------------------------------------"

    total=0
    copy_bytes=0
    drop_bytes=0

    echo
    echo "=== /var (top-level) ==="
    for p in /var/* /var/.[!.]*; do
        [ -e "${p}" ] || continue
        scan_one "${p}" "${p#/var/}"
    done

    echo
    echo "=== /var/lib ==="
    for p in /var/lib/*; do
        [ -e "${p}" ] || continue
        scan_one "${p}" "lib/${p##*/}"
    done

    echo
    echo "=== /var/cache ==="
    for p in /var/cache/*; do
        [ -e "${p}" ] || continue
        scan_one "${p}" "cache/${p##*/}"
    done

    echo
    echo "TOTAL /var=$(fmt "${total}")  COPY=$(fmt "${copy_bytes}")  DROP=$(fmt "${drop_bytes}")"
    echo "COPY must stay well under guest RAM (${QEMU_MEM} MB)."
} | tee ${OUT:+"${OUT}"}
