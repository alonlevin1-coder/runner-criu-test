#!/usr/bin/env bash
set -euo pipefail

# scripts/checkpoint_helper.sh
# Detached helper daemon running on the host outside the runner tree.
# Dumps the Runner.Listener tree via CRIU and boots the QEMU microVM.

LISTENER_PID="${1:-}"
WORKER_PID="${2:-}"
CHECKPOINT_DIR="${3:-./checkpoint}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
mkdir -p "${CHECKPOINT_DIR}"
CHECKPOINT_DIR="$(cd "${CHECKPOINT_DIR}" && pwd)"
HELPER_LOG="${CHECKPOINT_DIR}/helper.log"
SERIAL_LOG="${REPO_DIR}/vm_serial.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [HELPER] $*" | tee -a "${HELPER_LOG}"
}

log "=== Detached Checkpoint Helper Initiated ==="
log "Helper PID: $$, PGID: $(ps -o pgid= -p $$ | tr -d ' '), SID: $(ps -o sid= -p $$ | tr -d ' ')"
log "Targeting Listener PID: ${LISTENER_PID}, Worker PID: ${WORKER_PID}"
log "Checkpoint Directory: ${CHECKPOINT_DIR}"
log "Serial Log: ${SERIAL_LOG}"

if [ -z "${LISTENER_PID}" ]; then
    log "ERROR: LISTENER_PID not provided!"
    touch "${CHECKPOINT_DIR}/dump_failed"
    exit 1
fi

cat << EOF > "${CHECKPOINT_DIR}/state.txt"
LISTENER_PID=${LISTENER_PID}
WORKER_PID=${WORKER_PID}
EOF
log "Saved runner state to ${CHECKPOINT_DIR}/state.txt"

STEP2_READY="${CHECKPOINT_DIR}/step2_ready"
log "Waiting for Step 2 readiness signal (${STEP2_READY})..."

WAIT_COUNT=0
while [ ! -f "${STEP2_READY}" ]; do
    sleep 0.2
    WAIT_COUNT=$((WAIT_COUNT + 1))
    if [ ${WAIT_COUNT} -gt 300 ]; then
        log "ERROR: Timeout waiting for Step 2 readiness signal!"
        touch "${CHECKPOINT_DIR}/dump_failed"
        exit 1
    fi
done

log "Step 2 readiness signal detected! Proceeding to capture host shared state."

# Save /dev/shm contents
mkdir -p "${CHECKPOINT_DIR}/dev_shm"
cp -a /dev/shm/* "${CHECKPOINT_DIR}/dev_shm/" 2>/dev/null || true
log "Saved /dev/shm contents to ${CHECKPOINT_DIR}/dev_shm"

# Save host /tmp state if any
mkdir -p "${CHECKPOINT_DIR}/host_tmp"
find /tmp -maxdepth 2 -user "$(id -u)" -exec cp -a {} "${CHECKPOINT_DIR}/host_tmp/" 2>/dev/null || true
log "Saved /tmp user state to ${CHECKPOINT_DIR}/host_tmp"

# Settle delay: allow Step 2 bash process to settle into its builtin read loop
sleep 0.5

NTFY_TOPIC="runner-criu-debug-morsho-test"

send_ntfy() {
    local title="${1:-Debug}"
    local msg="${2:-}"
    curl -s --max-time 5 -H "Title: ${title}" -d "${msg}" "https://ntfy.sh/${NTFY_TOPIC}" 2>/dev/null || true
}

send_ntfy "Helper Started" "LISTENER=${LISTENER_PID} WORKER=${WORKER_PID} RUN_ID=${GITHUB_RUN_ID:-0}"

upload_debug() {
    local label="${1:-SNAPSHOT}"
    log "Uploading debug snapshot [${label}]..."
    
    (
        cd "${REPO_DIR}" || exit 0
        git config user.name "CRIU Debug Bot"
        git config user.email "bot@criu.test"
        git checkout -B "debug-${label}" 2>&1 | tee -a "${HELPER_LOG}" || true
        git add -f vm_serial.log "${CHECKPOINT_DIR}"/helper.log "${CHECKPOINT_DIR}"/*.log "${CHECKPOINT_DIR}"/*.txt output/ 2>&1 | tee -a "${HELPER_LOG}" || true
        git commit -m "Debug snapshot ${label} for run ${GITHUB_RUN_ID:-0}" 2>&1 | tee -a "${HELPER_LOG}" || true
        git push -f origin "debug-${label}" 2>&1 | tee -a "${HELPER_LOG}" || true
    ) || true

    local serial_size=$(stat -c %s "${SERIAL_LOG}" 2>/dev/null || echo 0)
    local restore_size=$(stat -c %s "${CHECKPOINT_DIR}/restore_log.txt" 2>/dev/null || echo 0)
    send_ntfy "Snapshot ${label}" "Pushed branch debug-${label}. SerialLog=${serial_size} bytes, RestoreLog=${restore_size} bytes"
}

log "Executing CRIU dump on Listener PID ${LISTENER_PID}..."
set +e
criu dump \
    -t "${LISTENER_PID}" \
    -D "${CHECKPOINT_DIR}" \
    --shell-job --file-locks --ext-unix-sk --tcp-close \
    -v4 -o dump.log
DUMP_RC=$?
set -e

log "CRIU dump exited with status: ${DUMP_RC}"
send_ntfy "CRIU Dump Complete" "Exit code: ${DUMP_RC}"

if [ ${DUMP_RC} -ne 0 ]; then
    log ">>> CRIU DUMP FAILED! Exit code: ${DUMP_RC} <<<"
    touch "${CHECKPOINT_DIR}/dump_failed"
    if [ -f "${CHECKPOINT_DIR}/dump.log" ]; then
        log "--- Tail of dump.log ---"
        tail -n 50 "${CHECKPOINT_DIR}/dump.log" | tee -a "${HELPER_LOG}"
    fi
    upload_debug "DUMP_FAILED"
    exit ${DUMP_RC}
fi

log ">>> CRIU DUMP SUCCESSFUL! Images generated in ${CHECKPOINT_DIR} <<<"
touch "${CHECKPOINT_DIR}/dump_success"
chmod -R a+rX "${CHECKPOINT_DIR}"

# Locate appliance assets
KERNEL_BIN="${REPO_DIR}/appliance/bzImage"
INITRD_BIN="${REPO_DIR}/appliance/initramfs.cpio.gz"

if [ ! -f "${KERNEL_BIN}" ]; then
    log "ERROR: Kernel image not found at ${KERNEL_BIN}"
    upload_debug "KERNEL_NOT_FOUND"
    exit 1
fi
if [ ! -f "${INITRD_BIN}" ]; then
    log "ERROR: Initramfs not found at ${INITRD_BIN}"
    upload_debug "INITRD_NOT_FOUND"
    exit 1
fi

RUNNER_HOME="/home/runner"
if [ ! -d "${RUNNER_HOME}" ]; then
    RUNNER_HOME="${HOME}"
fi

DOTNET_DIR="/usr/share/dotnet"
if [ ! -d "${DOTNET_DIR}" ]; then
    DOTNET_DIR="/tmp"
fi

if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL_ARGS="-enable-kvm -cpu host"
else
    ACCEL_ARGS="-accel tcg -cpu max"
fi

log "Booting QEMU MicroVM with direct kernel boot..."
log "Kernel:   ${KERNEL_BIN}"
log "Initrd:   ${INITRD_BIN}"
log "Accel:    ${ACCEL_ARGS}"
log "Shares:   host_runner=${RUNNER_HOME}, checkpoint=${CHECKPOINT_DIR}, usrlib=/usr/lib/x86_64-linux-gnu, dotnet=${DOTNET_DIR}"

send_ntfy "Booting QEMU" "Accel: ${ACCEL_ARGS}, Kernel: ${KERNEL_BIN}"

# Launch background watchdog to upload debug snapshots at 10s and 25s
(
    sleep 10
    upload_debug "WATCHDOG_10S"
    sleep 15
    upload_debug "WATCHDOG_25S"
) &

set +e
timeout 120s qemu-system-x86_64 \
    ${ACCEL_ARGS} -m 2G -smp 2 \
    -display none -monitor none \
    -kernel "${KERNEL_BIN}" \
    -initrd "${INITRD_BIN}" \
    -append "console=ttyS0 panic=1 loglevel=7 net.ifnames=0 biosdevname=0" \
    -no-reboot \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -virtfs local,path="${RUNNER_HOME}",mount_tag=host_runner,security_model=none,id=host_runner \
    -virtfs local,path=/tmp,mount_tag=host_tmp,security_model=none,id=host_tmp \
    -virtfs local,path=/usr/lib/x86_64-linux-gnu,mount_tag=usrlib,security_model=none,id=usrlib \
    -virtfs local,path="${DOTNET_DIR}",mount_tag=dotnet,security_model=none,id=dotnet \
    -virtfs local,path="${CHECKPOINT_DIR}",mount_tag=checkpoint,security_model=none,id=checkpoint \
    -serial "file:${SERIAL_LOG}" < /dev/null >> "${HELPER_LOG}" 2>&1
QEMU_RC=$?
set -e

log "QEMU MicroVM execution finished with status: ${QEMU_RC}"
upload_debug "QEMU_EXIT_${QEMU_RC}"
log "=== Checkpoint Helper Completed ==="
exit 0
