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
    printf '%s' "${msg}" | curl -s --max-time 10 -H "Title: ${title}" --data-binary @- "https://ntfy.sh/${NTFY_TOPIC}" 2>/dev/null || true
}

send_ntfy "Helper Started" "LISTENER=${LISTENER_PID} WORKER=${WORKER_PID} RUN_ID=${GITHUB_RUN_ID:-0}"

upload_debug() {
    local label="${1:-SNAPSHOT}"
    log "Uploading debug snapshot [${label}]..."
    set +e
    chmod -R a+rX "${CHECKPOINT_DIR}" "${SERIAL_LOG}" /tmp/daemon_helper.log 2>/dev/null || true

    local serial_tail=$(tail -n 35 "${SERIAL_LOG}" 2>/dev/null || echo "no serial log")
    local restore_tail=$(tail -n 35 "${CHECKPOINT_DIR}/restore_log.txt" 2>/dev/null || echo "no restore log")
    local helper_tail=$(tail -n 20 "${HELPER_LOG}" 2>/dev/null || echo "no helper log")

    # Immediate ntfy notifications with text body using --data-binary @-
    send_ntfy "VM [${label}] Serial" "${serial_tail}"
    send_ntfy "VM [${label}] Restore" "${restore_tail}"
    send_ntfy "VM [${label}] Helper" "${helper_tail}"

    # Git branch upload (TEXT/LOG FILES ONLY, NEVER binary .img files)
    (
        cd "${REPO_DIR}" || exit 0
        git config --global --add safe.directory "*"
        git config user.name "CRIU Debug Bot"
        git config user.email "bot@criu.test"
        git checkout -B "debug-${label}" 2>&1 | tee -a "${HELPER_LOG}" || true
        mkdir -p debug_logs
        cp -a "${CHECKPOINT_DIR}"/*.log "${CHECKPOINT_DIR}"/*.txt debug_logs/ 2>/dev/null || true
        [ -f "${SERIAL_LOG}" ] && cp -a "${SERIAL_LOG}" debug_logs/ 2>/dev/null || true
        [ -f /tmp/daemon_helper.log ] && cp -a /tmp/daemon_helper.log debug_logs/ 2>/dev/null || true
        git add debug_logs/ 2>&1 | tee -a "${HELPER_LOG}" || true
        git commit -m "Debug snapshot ${label} for run ${GITHUB_RUN_ID:-0}" 2>&1 | tee -a "${HELPER_LOG}" || true
        timeout 15s git push -f origin "debug-${label}" 2>&1 | tee -a "${HELPER_LOG}" || true
    ) || true
}

CRIU_BIN="$(command -v criu || true)"
if [ -x /usr/sbin/criu ]; then
    CRIU_BIN="/usr/sbin/criu"
fi
if [ -z "${CRIU_BIN}" ] || [ ! -x "${CRIU_BIN}" ]; then
    log "ERROR: criu binary not found"
    touch "${CHECKPOINT_DIR}/dump_failed"
    exit 1
fi
log "Using CRIU binary: ${CRIU_BIN} ($("${CRIU_BIN}" --version 2>/dev/null | head -n 1 || true))"
log "CPU model: $(grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2- | xargs || true)"
log "CPU xsave flags: $(grep -m1 '^flags' /proc/cpuinfo | tr ' ' '\n' | grep -E '^(xsave|osxsave|avx512|amx)' | tr '\n' ' ' || true)"
if [ -x /tmp/xsave_size ]; then
    log "$(/tmp/xsave_size)"
fi
send_ntfy "CRIU Host Caps" "bin=${CRIU_BIN}
$(${CRIU_BIN} --version 2>/dev/null | head -n 2)
$(grep -m1 '^model name' /proc/cpuinfo)
$(/tmp/xsave_size 2>/dev/null || true)"

DUMP_ATTEMPTS=0
DUMP_RC=1
while [ ${DUMP_ATTEMPTS} -lt 3 ] && [ ${DUMP_RC} -ne 0 ]; do
    DUMP_ATTEMPTS=$((DUMP_ATTEMPTS + 1))
    log "Executing CRIU dump on Listener PID ${LISTENER_PID} (attempt ${DUMP_ATTEMPTS}/3)..."
    find "${CHECKPOINT_DIR}" -maxdepth 1 \( -name '*.img' -o -name 'dump.log' \) -delete 2>/dev/null || true
    set +e
    sudo "${CRIU_BIN}" dump \
        -t "${LISTENER_PID}" \
        -D "${CHECKPOINT_DIR}" \
        --shell-job --file-locks --ext-unix-sk --tcp-close \
        --ghost-limit 32M \
        -v4 -o dump.log
    DUMP_RC=$?
    set -e
    log "CRIU dump attempt ${DUMP_ATTEMPTS} exited with status: ${DUMP_RC}"
    if [ ${DUMP_RC} -ne 0 ]; then
        sleep 1
    fi
done

chmod -R a+rX "${CHECKPOINT_DIR}" /tmp/daemon_helper.log "${SERIAL_LOG}" 2>/dev/null || true

if [ ${DUMP_RC} -ne 0 ]; then
    log ">>> CRIU DUMP FAILED! Exit code: ${DUMP_RC} <<<"
    touch "${CHECKPOINT_DIR}/dump_failed"
    dump_tail=""
    if [ -f "${CHECKPOINT_DIR}/dump.log" ]; then
        log "--- Tail of dump.log ---"
        tail -n 60 "${CHECKPOINT_DIR}/dump.log" | tee -a "${HELPER_LOG}"
        dump_tail=$(tail -n 30 "${CHECKPOINT_DIR}/dump.log" 2>/dev/null || echo "")
    fi
    send_ntfy "CRIU Dump Failed" "RC=${DUMP_RC}
${dump_tail}"
    upload_debug "DUMP_FAILED"
    exit ${DUMP_RC}
fi

send_ntfy "CRIU Dump Complete" "Exit code: 0"
log ">>> CRIU DUMP SUCCESSFUL! Images generated in ${CHECKPOINT_DIR} <<<"
touch "${CHECKPOINT_DIR}/dump_success"

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
log "KVM node: $(ls -l /dev/kvm 2>&1 || true)"
command -v qemu-system-x86_64 | tee -a "${HELPER_LOG}" || true

# Truncate serial so watchdog size is meaningful
: > "${SERIAL_LOG}"
chmod 666 "${SERIAL_LOG}"
QEMU_DEBUG_LOG="${CHECKPOINT_DIR}/qemu.log"

set +e
qemu-system-x86_64 \
    ${ACCEL_ARGS} -m 2G -smp 2 \
    -display none -monitor none \
    -kernel "${KERNEL_BIN}" \
    -initrd "${INITRD_BIN}" \
    -append "earlyprintk=ttyS0 console=ttyS0 panic=1 loglevel=7 net.ifnames=0 biosdevname=0" \
    -no-reboot \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -virtfs local,path="${RUNNER_HOME}",mount_tag=host_runner,security_model=none,id=host_runner \
    -virtfs local,path=/tmp,mount_tag=host_tmp,security_model=none,id=host_tmp \
    -virtfs local,path=/usr/lib/x86_64-linux-gnu,mount_tag=usrlib,security_model=none,id=usrlib \
    -virtfs local,path="${DOTNET_DIR}",mount_tag=dotnet,security_model=none,id=dotnet \
    -virtfs local,path="${CHECKPOINT_DIR}",mount_tag=checkpoint,security_model=none,id=checkpoint \
    -D "${QEMU_DEBUG_LOG}" \
    -serial "file:${SERIAL_LOG}" < /dev/null >> "${HELPER_LOG}" 2>&1 &
QEMU_PID=$!
set -e

sleep 0.3
QEMU_ALIVE="no"
if kill -0 "${QEMU_PID}" 2>/dev/null; then
    QEMU_ALIVE="yes"
fi
SERIAL_BYTES=$(wc -c < "${SERIAL_LOG}" 2>/dev/null | tr -d ' ' || echo 0)
log "QEMU launched pid=${QEMU_PID} alive=${QEMU_ALIVE} serial_bytes=${SERIAL_BYTES}"
send_ntfy "QEMU PID ${QEMU_PID}" "alive=${QEMU_ALIVE} serial_bytes=${SERIAL_BYTES} kvm=$(ls -l /dev/kvm 2>&1)
$(ps -o pid,stat,etime,cmd -p ${QEMU_PID} 2>/dev/null || echo 'ps: qemu pid gone')
--- helper ---
$(tail -n 25 "${HELPER_LOG}" 2>/dev/null || true)"

# Watchdog: always ntfy, even when serial is empty
(
    set +e
    for i in 0 1 2 3 4 5 6 7 8 9 10 12 14 16 18 20; do
        chmod -R a+rX "${CHECKPOINT_DIR}" "${SERIAL_LOG}" /tmp/daemon_helper.log 2>/dev/null || true
        serial_sz=$(wc -c < "${SERIAL_LOG}" 2>/dev/null | tr -d ' ' || echo 0)
        qemu_alive=no
        kill -0 "${QEMU_PID}" 2>/dev/null && qemu_alive=yes
        serial_tail=$(tail -n 25 "${SERIAL_LOG}" 2>/dev/null || echo "(empty)")
        helper_tail=$(tail -n 20 "${HELPER_LOG}" 2>/dev/null || echo "(empty)")
        restore_tail=$(tail -n 20 "${CHECKPOINT_DIR}/restore_log.txt" 2>/dev/null || echo "(no restore log)")
        qemu_dbg=$(tail -n 15 "${QEMU_DEBUG_LOG}" 2>/dev/null || echo "(no qemu.log)")
        send_ntfy "Watchdog ${i}" "qemu_pid=${QEMU_PID} alive=${qemu_alive} serial_bytes=${serial_sz}
--- serial ---
${serial_tail}
--- helper ---
${helper_tail}
--- restore ---
${restore_tail}
--- qemu.log ---
${qemu_dbg}"
        if [ -f "${CHECKPOINT_DIR}/step3_verification.txt" ]; then
            send_ntfy "STEP 3 VERIFIED IN VM!" "$(cat "${CHECKPOINT_DIR}/step3_verification.txt")"
            break
        fi
        sleep 4
    done
) &
WATCHDOG_PID=$!

# Hard deadline: SIGKILL QEMU after 90s (GNU timeout is unreliable after setsid)
(
    sleep 90
    if kill -0 "${QEMU_PID}" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [HELPER] Hard-killing QEMU pid ${QEMU_PID} after 90s" >> "${HELPER_LOG}"
        kill -9 "${QEMU_PID}" 2>/dev/null || true
        sleep 1
        kill -9 "${QEMU_PID}" 2>/dev/null || true
    fi
) &
KILLER_PID=$!

set +e
wait "${QEMU_PID}"
QEMU_RC=$?
set -e

kill -9 "${WATCHDOG_PID}" "${KILLER_PID}" 2>/dev/null || true

log "QEMU MicroVM execution finished pid=${QEMU_PID} status=${QEMU_RC} serial_bytes=$(wc -c < "${SERIAL_LOG}" 2>/dev/null | tr -d ' ' || echo 0)"
upload_debug "QEMU_EXIT_${QEMU_RC}"

# If Step 3 was not verified and QEMU exited, cancel orphaned workflow run to fail fast
if [ ! -f "${CHECKPOINT_DIR}/step3_verification.txt" ] && [ -n "${GITHUB_RUN_ID:-}" ] && [ "${GITHUB_RUN_ID}" != "0" ]; then
    log "Migration did not complete before QEMU exit. Cancelling orphaned workflow run ${GITHUB_RUN_ID}..."
    send_ntfy "Workflow Auto-Cancel" "Cancelling run ${GITHUB_RUN_ID} because QEMU exited (RC=${QEMU_RC}) without completing Step 3"
    gh run cancel "${GITHUB_RUN_ID}" 2>/dev/null || true
fi

log "=== Checkpoint Helper Completed ==="
exit 0
