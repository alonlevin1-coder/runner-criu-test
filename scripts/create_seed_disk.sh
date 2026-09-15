#!/usr/bin/env bash
# ==============================================================================
# create_seed_disk.sh
# Creates guest-local ext4 storage for dynamic state (/home, /var, /root).
#
# Modes:
#   1. CI Mode (on real GitHub runner, /home/runner exists):
#      Builds seed.img (raw ext4) from /home/runner and /var.
#   2. Local Dev Mode (on developer PC):
#      Builds a lightweight base template (/tmp/runner_seed_base.raw) ONCE,
#      then instantly produces a disposable Copy-on-Write overlay (qcow2)
#      in 5ms without copying the local PC's bloated home directory.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET_IMAGE="${1:-}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

# Auto-detect CI vs Local
IS_CI=0
if [ -d "/home/runner" ]; then
    IS_CI=1
fi

if [ -z "${TARGET_IMAGE}" ]; then
    if [ "${IS_CI}" -eq 1 ]; then
        TARGET_IMAGE="/tmp/seed.img"
    else
        TARGET_IMAGE="/tmp/runner_seed_test.qcow2"
    fi
fi

TARGET_DIR="$(dirname "${TARGET_IMAGE}")"
mkdir -p "${TARGET_DIR}"

if [ "${IS_CI}" -eq 1 ]; then
    echo "=== [SEED DISK] CI Environment Detected (GitHub-hosted Runner) ==="
    
    # Calculate exact size of /var, /home/runner, /root + 25% headroom
    VAR_MB=$(sudo du -sm /var 2>/dev/null | tail -n1 | awk '{print $1}' || echo 1500)
    [[ "${VAR_MB}" =~ ^[0-9]+$ ]] || VAR_MB=1500
    HOME_MB=$(sudo du -sm /home/runner 2>/dev/null | tail -n1 | awk '{print $1}' || echo 3000)
    [[ "${HOME_MB}" =~ ^[0-9]+$ ]] || HOME_MB=3000
    ROOT_MB=$(sudo du -sm /root 2>/dev/null | tail -n1 | awk '{print $1}' || echo 50)
    [[ "${ROOT_MB}" =~ ^[0-9]+$ ]] || ROOT_MB=50
    TOTAL_MB=$((VAR_MB + HOME_MB + ROOT_MB))
    SEED_SIZE_MB=$(( (TOTAL_MB * 125) / 100 ))
    
    # Ensure minimum 4096MB and maximum 12288MB
    [ "${SEED_SIZE_MB}" -lt 4096 ] && SEED_SIZE_MB=4096
    [ "${SEED_SIZE_MB}" -gt 12288 ] && SEED_SIZE_MB=12288

    echo "--- Sizing: /var=${VAR_MB}MB, /home/runner=${HOME_MB}MB -> seed disk=${SEED_SIZE_MB}MB ---"
    rm -f "${TARGET_IMAGE}"
    truncate -s "${SEED_SIZE_MB}M" "${TARGET_IMAGE}"
    mkfs.ext4 -F -q -L "runner-seed" "${TARGET_IMAGE}"

    MOUNT_POINT="/tmp/mnt_seed_build_$$"
    mkdir -p "${MOUNT_POINT}"
    sudo mount -o loop "${TARGET_IMAGE}" "${MOUNT_POINT}"

    echo "--- Seeding /var, /home, /root into seed disk ---"
    sudo mkdir -p "${MOUNT_POINT}/var" "${MOUNT_POINT}/home/runner" "${MOUNT_POINT}/root"
    
    safe_rsync() {
        local logfile
        logfile="$(mktemp)"
        set +e
        sudo rsync -v "$@" 2>"${logfile}"
        local rc=$?
        set -e
        # rsync exit code 24 = vanished/modified source files (e.g. active log rotation)
        if [ "$rc" -eq 24 ]; then
            echo "[SEED DISK] rsync note: source files vanished during sync (rc=24):"
            grep -E 'vanished|No such file' "${logfile}" || cat "${logfile}"
        elif [ "$rc" -ne 0 ]; then
            echo "[SEED DISK] rsync warning: exited with code ${rc}" >&2
            cat "${logfile}" >&2
        fi
        rm -f "${logfile}"
        return 0
    }

    # Copy /var excluding runtime/lock/docker cache that restarts clean
    safe_rsync -aHAX --exclude='/var/run' --exclude='/var/lock' --exclude='/var/tmp/*' /var/ "${MOUNT_POINT}/var/"
    # Copy runner homedir
    safe_rsync -aHAX /home/runner/ "${MOUNT_POINT}/home/runner/"
    # Copy root homedir
    safe_rsync -aHAX /root/ "${MOUNT_POINT}/root/" 2>/dev/null || true

    # Fix runner permissions
    sudo chown -R 1001:1001 "${MOUNT_POINT}/home/runner" 2>/dev/null || true

    sudo umount "${MOUNT_POINT}"
    rm -rf "${MOUNT_POINT}"
    chmod 666 "${TARGET_IMAGE}" 2>/dev/null || true
    echo "=== [SEED DISK] Ready: ${TARGET_IMAGE} (${SEED_SIZE_MB}MB, raw ext4) ==="
    echo "OUTPUT_FORMAT=raw"
    echo "OUTPUT_PATH=${TARGET_IMAGE}"
else
    echo "=== [SEED DISK] Local Dev Environment Detected (Non-Runner Host) ==="
    BASE_TEMPLATE="/tmp/runner_seed_base.raw"
    BASE_SIZE_MB=1024

    # Build base template once (unless forced)
    if [ ! -f "${BASE_TEMPLATE}" ] || [ "${FORCE_REBUILD}" -eq 1 ]; then
        echo "--- Building base template once: ${BASE_TEMPLATE} (${BASE_SIZE_MB}MB) ---"
        rm -f "${BASE_TEMPLATE}"
        truncate -s "${BASE_SIZE_MB}M" "${BASE_TEMPLATE}"
        mkfs.ext4 -F -q -L "runner-seed" "${BASE_TEMPLATE}"

        MOUNT_POINT="/tmp/mnt_seed_base_$$"
        mkdir -p "${MOUNT_POINT}"
        sudo mount -o loop "${BASE_TEMPLATE}" "${MOUNT_POINT}"

        echo "--- Populating mock runner home and clean var ---"
        sudo mkdir -p "${MOUNT_POINT}/home/runner" "${MOUNT_POINT}/var/lib" "${MOUNT_POINT}/var/log" "${MOUNT_POINT}/var/tmp" "${MOUNT_POINT}/root"
        
        # Copy minimal /etc-matching skeleton into runner home
        sudo cp -a /etc/skel/. "${MOUNT_POINT}/home/runner/" 2>/dev/null || true
        # Create mock runner marker and workspace
        sudo mkdir -p "${MOUNT_POINT}/home/runner/work" "${MOUNT_POINT}/home/runner/_diag"
        echo "mock-runner-local" | sudo tee "${MOUNT_POINT}/home/runner/.runner_env" >/dev/null

        # If current user homedir has runner repo, expose a symlink / copy test workload
        sudo chown -R 1001:1001 "${MOUNT_POINT}/home/runner" 2>/dev/null || true
        sudo chmod 1777 "${MOUNT_POINT}/var/tmp"

        # Copy authorized ssh keys to root if present
        sudo mkdir -p "${MOUNT_POINT}/root/.ssh"
        if [ -f "${REPO_DIR}/appliance/ssh_id_ed25519.pub" ]; then
            sudo cat "${REPO_DIR}/appliance/ssh_id_ed25519.pub" | sudo tee -a "${MOUNT_POINT}/root/.ssh/authorized_keys" >/dev/null
        fi
        if [ -f "${HOME}/.ssh/authorized_keys" ]; then
            sudo cat "${HOME}/.ssh/authorized_keys" | sudo tee -a "${MOUNT_POINT}/root/.ssh/authorized_keys" >/dev/null
        fi
        sudo chmod 700 "${MOUNT_POINT}/root" "${MOUNT_POINT}/root/.ssh"
        sudo chmod 600 "${MOUNT_POINT}/root/.ssh/authorized_keys" 2>/dev/null || true

        sudo umount "${MOUNT_POINT}"
        rm -rf "${MOUNT_POINT}"
        chmod 666 "${BASE_TEMPLATE}" 2>/dev/null || true
        echo "--- Base template built successfully ---"
    else
        echo "--- Reusing existing base template: ${BASE_TEMPLATE} ---"
    fi

    # Create instant CoW overlay in 5 milliseconds
    rm -f "${TARGET_IMAGE}"
    qemu-img create -f qcow2 -b "${BASE_TEMPLATE}" -F raw "${TARGET_IMAGE}" >/dev/null
    chmod 666 "${TARGET_IMAGE}" 2>/dev/null || true

    echo "=== [SEED DISK] Instant CoW Overlay Ready: ${TARGET_IMAGE} (qcow2) ==="
    echo "OUTPUT_FORMAT=qcow2"
    echo "OUTPUT_PATH=${TARGET_IMAGE}"
fi
