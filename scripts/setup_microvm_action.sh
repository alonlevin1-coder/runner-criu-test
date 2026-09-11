#!/usr/bin/env bash
# scripts/setup_microvm_action.sh
# Driver script for the MicroVM Migration composite action.
# Sets up host prerequisites, initiates CRIU checkpoint/migration, and handles the
# host/guest split so all subsequent workflow steps execute inside the MicroVM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="$(cd "${ACTION_DIR:-${SCRIPT_DIR}/..}" && pwd)"

log() { echo "[setup_microvm_action] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# 1. If already executing inside the microVM, no-op immediately
if [ -f /tmp/is_vm ]; then
    log "Already executing inside MicroVM (/tmp/is_vm detected). Succeeded."
    exit 0
fi

log "Initializing MicroVM migration from ${ACTION_DIR}..."

# 2. Check and install system packages if missing
NEEDED_PACKAGES=()
for pkg in qemu-system-x86 dropbear-bin socat; do
    if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
        NEEDED_PACKAGES+=("${pkg}")
    fi
done

if [ "${#NEEDED_PACKAGES[@]}" -gt 0 ]; then
    log "Installing missing system packages: ${NEEDED_PACKAGES[*]}"
    export DEBIAN_FRONTEND=noninteractive
    SUDO=""
    [ "$(id -u)" -ne 0 ] && SUDO="sudo"
    # Fast path: try installing directly using runner's pre-warmed apt cache
    if ! ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
        -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "${NEEDED_PACKAGES[@]}" >/dev/null 2>&1; then
        log "Fast apt install failed; updating package lists and retrying..."
        ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get update -y -q
        ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
            -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "${NEEDED_PACKAGES[@]}"
    fi
fi

# 3. Ensure CRIU binary is installed (use pre-packaged binary if available)
CRIU_BIN="$(command -v criu || true)"
[ -x /usr/sbin/criu ] && CRIU_BIN="/usr/sbin/criu"
[ -x /usr/local/sbin/criu ] && CRIU_BIN="/usr/local/sbin/criu"

if [ -z "${CRIU_BIN}" ] || [ ! -x "${CRIU_BIN}" ]; then
    if [ -x "${ACTION_DIR}/bin/criu" ]; then
        log "Installing pre-packaged CRIU binary from ${ACTION_DIR}/bin/criu..."
        SUDO=""
        [ "$(id -u)" -ne 0 ] && SUDO="sudo"
        ${SUDO} cp -a "${ACTION_DIR}/bin/criu" /usr/local/sbin/criu
        if [ -d "${ACTION_DIR}/bin/lib" ]; then
            ${SUDO} cp -a "${ACTION_DIR}/bin/lib"/* /usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
            ${SUDO} cp -a "${ACTION_DIR}/bin/lib"/* /usr/local/lib/ 2>/dev/null || true
            ${SUDO} ldconfig 2>/dev/null || true
        fi
        CRIU_BIN="/usr/local/sbin/criu"
    else
        log "CRIU binary not found. Building CRIU from source with expanded XSAVE buffers..."
        chmod +x "${ACTION_DIR}/scripts/build_criu.sh"
        "${ACTION_DIR}/scripts/build_criu.sh"
        CRIU_BIN="$(command -v criu || true)"
        [ -x /usr/sbin/criu ] && CRIU_BIN="/usr/sbin/criu"
    fi
fi
log "Using CRIU binary: ${CRIU_BIN} ($("${CRIU_BIN}" --version 2>/dev/null || true))"

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
else
    log "Using pre-packaged initramfs: ${ACTION_DIR}/appliance/initramfs.cpio.gz ($(ls -lh "${ACTION_DIR}/appliance/initramfs.cpio.gz" | awk '{print $5}'))"
fi

# 6. Make all helper scripts executable
chmod +x "${ACTION_DIR}"/scripts/*.sh "${ACTION_DIR}"/appliance/*.sh 2>/dev/null || true
chmod 600 "${ACTION_DIR}/appliance/ssh_id_ed25519" 2>/dev/null || true

# 7. Setup checkpoint and log directories
# Must be outside GITHUB_WORKSPACE so actions/checkout doesn't fail trying to clean root files
CHECKPOINT_DIR="${RUNNER_VM_CHECKPOINT:-${CHECKPOINT_DIR:-/tmp/runner_checkpoint}}"
LOG_DIR="${LOG_DIR:-/tmp/runner_logs}"
mkdir -p "${CHECKPOINT_DIR}" "${LOG_DIR}"
echo "${CHECKPOINT_DIR}" > "${CHECKPOINT_DIR}/checkpoint_dir.txt"
chmod a+rw "${CHECKPOINT_DIR}/checkpoint_dir.txt" 2>/dev/null || true
log "Checkpoint dir: ${CHECKPOINT_DIR}"

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
