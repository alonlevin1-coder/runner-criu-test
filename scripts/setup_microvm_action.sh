#!/usr/bin/env bash
# scripts/setup_microvm_action.sh
# Driver script for the MicroVM Migration composite action.
# Sets up host prerequisites, initiates CRIU checkpoint/migration, and handles the
# host/guest split so all subsequent workflow steps execute inside the MicroVM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="$(cd "${ACTION_DIR:-${SCRIPT_DIR}/..}" && pwd)"

T9_T0="$(date +%s)"
T9_LAST="${T9_T0}"
log() { echo "[setup_microvm_action] $(date '+%Y-%m-%d %H:%M:%S') $*"; }
stage() {
    local now
    now="$(date +%s)"
    log "stage=${1} elapsed=$((now - T9_T0))s delta=$((now - T9_LAST))s ${2:-}"
    T9_LAST="${now}"
}

# shellcheck source=is_in_vm.sh
. "${SCRIPT_DIR}/is_in_vm.sh"

# 1. If already executing inside the microVM, no-op immediately
if is_in_vm; then
    log "Already executing inside MicroVM (procfs/hostname guest signal). Succeeded."
    exit 0
fi

log "Initializing MicroVM migration from ${ACTION_DIR}..."

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

apt_install() {
    export DEBIAN_FRONTEND=noninteractive
    if [ "$(id -u)" -eq 0 ]; then
        apt-get install -y -q --no-install-recommends -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$@"
    else
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$@"
    fi
}
apt_update() {
    export DEBIAN_FRONTEND=noninteractive
    if [ "$(id -u)" -eq 0 ]; then
        apt-get update -y -q
    else
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -y -q
    fi
}

# 2. QEMU/dropbear: dpkg only packages the image does not already have.
#    Never reinstall libc/libselinux — that can stall a live runner.
DEB_DIR="${ACTION_DIR}/appliance/debs"
INSTALLED_FROM_DEBS=0
shopt -s nullglob
VENDOR_DEBS=("${DEB_DIR}"/*.deb)
shopt -u nullglob
NEW_DEBS=()
for deb in "${VENDOR_DEBS[@]}"; do
    pkg="$(dpkg-deb -f "${deb}" Package 2>/dev/null || true)"
    [ -n "${pkg}" ] || continue
    case "${pkg}" in
        libc6|libselinux1|libssl3|libgcc-s1|libstdc++6) continue ;;
    esac
    if dpkg -s "${pkg}" >/dev/null 2>&1; then
        continue
    fi
    NEW_DEBS+=("${deb}")
done
if [ "${#NEW_DEBS[@]}" -gt 0 ]; then
    log "Installing ${#NEW_DEBS[@]} missing vendored debs (skipped already-installed)"
    if run_root dpkg -i "${NEW_DEBS[@]}" \
        || run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q -f --no-install-recommends \
            -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"; then
        INSTALLED_FROM_DEBS=1
    else
        log "Vendored debs failed; falling back to apt"
    fi
    stage "vendor_debs"
elif [ "${#VENDOR_DEBS[@]}" -gt 0 ]; then
    log "All vendored deb packages already installed"
    INSTALLED_FROM_DEBS=1
    stage "vendor_debs"
fi

NEEDED_PACKAGES=()
if [ "${INSTALLED_FROM_DEBS}" -eq 0 ]; then
    for pkg in qemu-system-x86 cpio gcc dropbear-bin openssh-client iproute2; do
        if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
            NEEDED_PACKAGES+=("${pkg}")
        fi
    done
fi

if [ "${#NEEDED_PACKAGES[@]}" -gt 0 ]; then
    log "Installing missing system packages: ${NEEDED_PACKAGES[*]}"
    if ! apt_install "${NEEDED_PACKAGES[@]}"; then
        log "apt install missed indexes; updating and retrying"
        apt_update
        apt_install "${NEEDED_PACKAGES[@]}"
    fi
    stage "apt_packages"
fi

# 3. Ensure CRIU binary is installed (build from source if not present)
CRIU_BIN=""
for c in "${ACTION_DIR}/bin/criu" /usr/sbin/criu /usr/local/sbin/criu; do
    if [ -x "${c}" ]; then
        CRIU_BIN="${c}"
        break
    fi
done
[ -z "${CRIU_BIN}" ] && CRIU_BIN="$(command -v criu || true)"

if [ -n "${CRIU_BIN}" ] && [ "${CRIU_BIN}" != /usr/sbin/criu ]; then
    log "Installing bundled CRIU to /usr/sbin (guest restore uses host /usr overlay)"
    if [ "$(id -u)" -eq 0 ]; then
        install -m 755 "${CRIU_BIN}" /usr/sbin/criu
    else
        sudo install -m 755 "${CRIU_BIN}" /usr/sbin/criu
    fi
    CRIU_BIN="/usr/sbin/criu"
fi

if [ -z "${CRIU_BIN}" ] || [ ! -x "${CRIU_BIN}" ]; then
    log "CRIU binary not found. Building CRIU from source with expanded XSAVE buffers..."
    chmod +x "${ACTION_DIR}/scripts/build_criu.sh"
    "${ACTION_DIR}/scripts/build_criu.sh"
    CRIU_BIN="$(command -v criu || true)"
    [ -x /usr/sbin/criu ] && CRIU_BIN="/usr/sbin/criu"
fi
log "Using CRIU binary: ${CRIU_BIN} ($("${CRIU_BIN}" --version 2>/dev/null || true))"
if command -v ldd >/dev/null && ldd "${CRIU_BIN}" 2>/dev/null | grep -q 'not found'; then
    log "CRIU missing shared libraries; installing runtime packages"
    if ! apt_install libprotobuf-c1 libnet1 libnftables1 libbsd0 libnl-3-200; then
        apt_update
        apt_install libprotobuf-c1 libnet1 libnftables1 libbsd0 libnl-3-200
    fi
fi
stage "criu"

# 4. Ensure daemonize helper binary exists
if [ ! -x "${ACTION_DIR}/scripts/daemonize" ]; then
    log "Compiling daemonize helper..."
    gcc -O2 -Wall "${ACTION_DIR}/scripts/daemonize.c" -o "${ACTION_DIR}/scripts/daemonize"
    chmod +x "${ACTION_DIR}/scripts/daemonize"
fi

# 5. Ensure initramfs is assembled
if [ ! -f "${ACTION_DIR}/appliance/initramfs.cpio.gz" ]; then
    log "Assembling QEMU MicroVM restore initramfs..."
    chmod +x "${ACTION_DIR}/appliance/assemble_initramfs.sh"
    "${ACTION_DIR}/appliance/assemble_initramfs.sh"
fi
stage "initramfs"

# 6. Make all helper scripts executable
chmod +x "${ACTION_DIR}"/scripts/*.sh "${ACTION_DIR}"/appliance/*.sh 2>/dev/null || true
chmod 600 "${ACTION_DIR}/appliance/ssh_id_ed25519" 2>/dev/null || true

# 7. Setup checkpoint and log directories
CHECKPOINT_DIR="${RUNNER_VM_CHECKPOINT:-${CHECKPOINT_DIR:-${GITHUB_WORKSPACE:-/tmp}/checkpoint}}"
LOG_DIR="${LOG_DIR:-${GITHUB_WORKSPACE:-/tmp}/smoke-logs}"
mkdir -p "${CHECKPOINT_DIR}" "${LOG_DIR}"
tr -d '[:space:]' < /proc/sys/kernel/random/boot_id > "${CHECKPOINT_DIR}/host_boot_id"
cat /proc/cmdline > "${CHECKPOINT_DIR}/host_cmdline" 2>/dev/null || true
chmod a+rw "${CHECKPOINT_DIR}/host_boot_id" "${CHECKPOINT_DIR}/host_cmdline" 2>/dev/null || true
log "Checkpoint dir: ${CHECKPOINT_DIR} host_boot_id=$(cat "${CHECKPOINT_DIR}/host_boot_id")"
chmod +x "${ACTION_DIR}/scripts/map_host_var.sh" "${ACTION_DIR}/scripts/pack_host_var.sh"
log "Mapping host /var (deny runtime/cache/images, copy remaining tool state)..."
"${ACTION_DIR}/scripts/map_host_var.sh" "${CHECKPOINT_DIR}/var_map.txt" || true
log "Packing COPY /var trees into checkpoint for the guest..."
if [ "$(id -u)" -eq 0 ]; then
    "${ACTION_DIR}/scripts/pack_host_var.sh" "${CHECKPOINT_DIR}"
else
    sudo "${ACTION_DIR}/scripts/pack_host_var.sh" "${CHECKPOINT_DIR}"
fi
stage "var_seed"

# 8. Configure TCP migration mode
CRIU_TCP_MODE="${INPUT_TCP_MODE:-${CRIU_TCP_MODE:-established}}"
echo "${CRIU_TCP_MODE}" > "${CHECKPOINT_DIR}/criu_tcp_mode.txt"
chmod a+rw "${CHECKPOINT_DIR}/criu_tcp_mode.txt" 2>/dev/null || true
log "TCP mode configured: ${CRIU_TCP_MODE}"

# 9. Isolate orchestrator step shell from CRIU freeze
STEP_SHELL_PID="${STEP_SHELL_PID:-$$}"
echo "${STEP_SHELL_PID}" > "${CHECKPOINT_DIR}/step_shell.pid"
echo "${STEP_SHELL_PID}" > "${CHECKPOINT_DIR}/freeze_exclude_pids.txt"
chmod a+rw "${CHECKPOINT_DIR}/step_shell.pid" "${CHECKPOINT_DIR}/freeze_exclude_pids.txt" 2>/dev/null || true

log "Mapping runner process tree..."
"${ACTION_DIR}/scripts/map_workflow_processes.sh" "${CHECKPOINT_DIR}" "${STEP_SHELL_PID}"

# 10. Identify Runner.Worker PID
WORKER_PID=$(pgrep -f 'Runner\.Worker' | head -n1 || true)
if [ -z "${WORKER_PID}" ]; then
    log "ERROR: Runner.Worker PID could not be found."
    exit 1
fi
log "Identified Runner.Worker PID: ${WORKER_PID}"

# 11. Launch migration daemon in background
export ALLOW_WORKER_DUMP=1
export KEEP_QEMU_ALIVE=1
export CRIU_TCP_MODE="${CRIU_TCP_MODE}"
export ISOLATE_HOST_TCP_AFTER_DUMP=1
export ACTIVATE_TAP_IMMEDIATELY=1
export QEMU_SMP="${INPUT_SMP:-${QEMU_SMP:-2}}"
export QEMU_MEM="${INPUT_MEMORY_MB:-${QEMU_MEM:-4096}}"
export NTFY_TOPIC="${INPUT_NTFY_TOPIC:-${NTFY_TOPIC:-}}"
export STEP_SHELL_PID

SERIAL_LOG="${LOG_DIR}/vm_serial.log"
log "Daemonizing migration helper (target_pid=${WORKER_PID}, tcp_mode=${CRIU_TCP_MODE})..."
if [ "$(id -u)" -eq 0 ]; then
    "${ACTION_DIR}/scripts/daemonize" \
        "${ACTION_DIR}/scripts/smoke_is_vm_helper.sh" \
        "${WORKER_PID}" \
        "${CHECKPOINT_DIR}" \
        "${ACTION_DIR}" \
        "${SERIAL_LOG}" \
        "worker"
else
    sudo -E "${ACTION_DIR}/scripts/daemonize" \
        "${ACTION_DIR}/scripts/smoke_is_vm_helper.sh" \
        "${WORKER_PID}" \
        "${CHECKPOINT_DIR}" \
        "${ACTION_DIR}" \
        "${SERIAL_LOG}" \
        "worker"
fi

# 12. Run is_vm_wait.sh
# Host branch waits for migrator_ok, then blocks forever via exec sleep (keeps host runner alive).
# Guest branch restores Runner.Worker via CRIU, where waitpid immediately returns success and
# advances to all subsequent workflow steps inside the MicroVM.
export RUNNER_VM_CHECKPOINT="${CHECKPOINT_DIR}"
export IS_VM_MAX_WAIT_SEC="${IS_VM_MAX_WAIT_SEC:-600}"
log "Awaiting microVM migration cutover and restore..."
"${ACTION_DIR}/scripts/is_vm_wait.sh"
stage "migrated"
