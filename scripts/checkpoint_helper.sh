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
CRIU_TCP_FLAG="$("${SCRIPT_DIR}/criu_tcp_flags.sh")"
CRIU_TCP_MODE="${CRIU_TCP_MODE:-close}"
mkdir -p "${CHECKPOINT_DIR}"
CHECKPOINT_DIR="$(cd "${CHECKPOINT_DIR}" && pwd)"
HELPER_LOG="${CHECKPOINT_DIR}/helper.log"
SERIAL_LOG="${REPO_DIR}/vm_serial.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [HELPER] $*" | tee -a "${HELPER_LOG}"
}

log "=== Detached Checkpoint Helper Initiated ==="
log "Helper PID: $$, PGID: $(ps -o pgid= -p $$ | tr -d ' '), SID: $(ps -o sid= -p $$ | tr -d ' ')"
log "Targeting dump PID: ${LISTENER_PID}, Worker PID: ${WORKER_PID}"
log "Checkpoint Directory: ${CHECKPOINT_DIR}"
log "Serial Log: ${SERIAL_LOG}"

if [ -z "${LISTENER_PID}" ]; then
    log "ERROR: LISTENER_PID not provided!"
    touch "${CHECKPOINT_DIR}/dump_failed"
    exit 1
fi

DUMP_CMDLINE=$(tr '\0' ' ' < "/proc/${LISTENER_PID}/cmdline" 2>/dev/null || true)
if echo "${DUMP_CMDLINE}" | grep -qE 'Runner\.(Listener|Worker)'; then
    if [ "${ALLOW_LISTENER_DUMP:-0}" != "1" ]; then
        log "REFUSING to dump Runner.* (set ALLOW_LISTENER_DUMP=1 for T9): ${DUMP_CMDLINE}"
        touch "${CHECKPOINT_DIR}/dump_failed"
        exit 2
    fi
    log "ALLOW_LISTENER_DUMP=1 — dumping runner process"
else
    log "Dump target is not Runner.* cmdline=${DUMP_CMDLINE}"
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
    # ntfy drops oversized payloads; never send kernel serial dumps.
    if [ "${#msg}" -gt 1800 ]; then
        msg="$(printf '%s' "${msg}" | tail -c 1800)"
    fi
    printf '%s' "${msg}" | curl -s --max-time 10 -H "Title: ${title}" --data-binary @- "https://ntfy.sh/${NTFY_TOPIC}" 2>/dev/null || true
}

send_ntfy "Helper Started" "PID=${LISTENER_PID} RUN_ID=${GITHUB_RUN_ID:-0} allow_listener=${ALLOW_LISTENER_DUMP:-0}"

upload_debug() {
    local label="${1:-SNAPSHOT}"
    log "Uploading debug snapshot [${label}]..."
    set +e
    chmod -R a+rX "${CHECKPOINT_DIR}" "${SERIAL_LOG}" /tmp/daemon_helper.log 2>/dev/null || true

    local progress="$(cat "${CHECKPOINT_DIR}/guest_progress.txt" 2>/dev/null || echo "(no guest_progress.txt)")"
    local guest_serial="$(grep -E '\[GUEST\]|QEMU Guest VM Booted|CRIU restore returned' "${SERIAL_LOG}" 2>/dev/null | tail -n 20 || true)"
    local restore_err="$(grep -E 'Error \(|CRIU restore' "${CHECKPOINT_DIR}/restore_log.txt" 2>/dev/null | tail -n 12 || echo "(no restore errors)")"

    send_ntfy "VM [${label}]" "progress:
${progress}
--- guest ---
${guest_serial:-no [GUEST] lines}
--- restore ---
${restore_err}"

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

DUMP_ATTEMPTS=0
DUMP_RC=1
while [ ${DUMP_ATTEMPTS} -lt 3 ] && [ ${DUMP_RC} -ne 0 ]; do
    DUMP_ATTEMPTS=$((DUMP_ATTEMPTS + 1))
    log "Executing CRIU dump on Listener PID ${LISTENER_PID} (attempt ${DUMP_ATTEMPTS}/3) tcp=${CRIU_TCP_FLAG}..."
    find "${CHECKPOINT_DIR}" -maxdepth 1 \( -name '*.img' -o -name 'dump.log' \) -delete 2>/dev/null || true
    echo "criu_tcp_mode=${CRIU_TCP_MODE}" >> "${CHECKPOINT_DIR}/state.txt"
    echo "${CRIU_TCP_MODE}" > "${CHECKPOINT_DIR}/criu_tcp_mode.txt"
    "${SCRIPT_DIR}/load_criu_tcp_modules.sh"
    set +e
    sudo "${CRIU_BIN}" dump \
        -t "${LISTENER_PID}" \
        -D "${CHECKPOINT_DIR}" \
        --shell-job --file-locks --ext-unix-sk "${CRIU_TCP_FLAG}" \
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

SSH_PORT="${SSH_PORT:-2222}"
SSH_KEY="${REPO_DIR}/appliance/ssh_id_ed25519"
chmod 600 "${SSH_KEY}" 2>/dev/null || true

log "Booting QEMU MicroVM (two-stage: SSH then criu restore)..."
log "Kernel:   ${KERNEL_BIN}"
log "Initrd:   ${INITRD_BIN}"
log "Accel:    ${ACCEL_ARGS}"
log "SSH:      127.0.0.1:${SSH_PORT} key=${SSH_KEY}"
log "Shares:   host_runner=${RUNNER_HOME}, checkpoint=${CHECKPOINT_DIR}, usrlib=/usr/lib/x86_64-linux-gnu, dotnet=${DOTNET_DIR}"
log "KVM node: $(ls -l /dev/kvm 2>&1 || true)"
command -v qemu-system-x86_64 | tee -a "${HELPER_LOG}" || true

# Truncate serial so watchdog size is meaningful
: > "${SERIAL_LOG}"
chmod 666 "${SERIAL_LOG}"
QEMU_DEBUG_LOG="${CHECKPOINT_DIR}/qemu.log"

VIRTFS_ARGS=(
    -virtfs "local,path=${RUNNER_HOME},mount_tag=host_runner,security_model=none,id=host_runner"
    -virtfs "local,path=/tmp,mount_tag=host_tmp,security_model=none,id=host_tmp"
    -virtfs "local,path=/usr/lib/x86_64-linux-gnu,mount_tag=usrlib,security_model=none,id=usrlib"
    -virtfs "local,path=${DOTNET_DIR},mount_tag=dotnet,security_model=none,id=dotnet"
    -virtfs "local,path=${CHECKPOINT_DIR},mount_tag=checkpoint,security_model=none,id=checkpoint"
)
for spec in "host_usr:/usr" "host_bin:/bin" "host_lib:/lib" "host_lib64:/lib64" "host_opt:/opt"; do
    tag="${spec%%:*}"
    path="${spec##*:}"
    if [ -d "${path}" ]; then
        VIRTFS_ARGS+=(-virtfs "local,path=${path},mount_tag=${tag},security_model=none,readonly=on,id=${tag}")
    fi
done

set +e
qemu-system-x86_64 \
    ${ACCEL_ARGS} -m 2G -smp 2 \
    -display none -monitor none \
    -kernel "${KERNEL_BIN}" \
    -initrd "${INITRD_BIN}" \
    -append "earlyprintk=ttyS0 console=ttyS0 panic=1 loglevel=7 net.ifnames=0 biosdevname=0 rdinit=/init" \
    -no-reboot \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    "${VIRTFS_ARGS[@]}" \
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

SSH=(ssh -i "${SSH_KEY}" -p "${SSH_PORT}" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -o BatchMode=yes root@127.0.0.1)

SSH_OK=0
for i in $(seq 1 60); do
    if [ -f "${SSH_KEY}" ] && "${SSH[@]}" 'echo SSH_PROBE_OK' >/dev/null 2>> "${HELPER_LOG}"; then
        SSH_OK=1
        log "SSH into appliance at ${i}s"
        break
    fi
    if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
        log "QEMU died before SSH"
        break
    fi
    sleep 1
done

if [ "${SSH_OK}" -eq 1 ]; then
    send_ntfy "SSH Ready" "appliance ssh up; running t9_restore.sh"
    log "Running /t9_restore.sh over SSH"
    set +e
    "${SSH[@]}" '/t9_restore.sh' | tee "${CHECKPOINT_DIR}/ssh_restore.txt" | tee -a "${HELPER_LOG}"
    RESTORE_RC=${PIPESTATUS[0]}
    set -e
    echo "${RESTORE_RC}" > "${CHECKPOINT_DIR}/restore.rc"
    log "t9_restore.sh rc=${RESTORE_RC}"
    send_ntfy "CRIU Restore SSH" "rc=${RESTORE_RC}
$(tail -n 20 "${CHECKPOINT_DIR}/ssh_restore.txt" 2>/dev/null || true)"
else
    log "SSH never came up; restore not invoked from host"
    touch "${CHECKPOINT_DIR}/ssh_failed"
    send_ntfy "SSH Failed" "could not reach dropbear on :${SSH_PORT}"
fi

# First sample after /init has had time to mount 9p. Then every 10s.
# Always append host_watchdog.txt so GHA artifacts work even if ntfy drops.
(
    set +e
    sleep 10
    for i in 1 2 3 4 5 6 7 8; do
        chmod -R a+rX "${CHECKPOINT_DIR}" "${SERIAL_LOG}" /tmp/daemon_helper.log 2>/dev/null || true
        serial_sz=$(wc -c < "${SERIAL_LOG}" 2>/dev/null | tr -d ' ' || echo 0)
        qemu_alive=no
        kill -0 "${QEMU_PID}" 2>/dev/null && qemu_alive=yes
        progress="$(cat "${CHECKPOINT_DIR}/guest_progress.txt" 2>/dev/null || echo "(no guest_progress.txt)")"
        guest_serial="$(grep -E '\[GUEST\]|QEMU Guest VM Booted|CRIU restore returned' "${SERIAL_LOG}" 2>/dev/null | tail -n 15 || true)"
        restore_err="$(grep -E 'Error \(' "${CHECKPOINT_DIR}/restore_log.txt" 2>/dev/null | tail -n 8 || echo "(no restore log)")"
        {
            echo "t=$(date -u +%H:%M:%S) i=${i} qemu=${qemu_alive} serial_bytes=${serial_sz}"
            echo "${progress}" | tail -n 5
            echo "---"
        } >> "${CHECKPOINT_DIR}/host_watchdog.txt"
        body="qemu=${qemu_alive} serial_bytes=${serial_sz}
--- progress ---
${progress}
--- guest ---
${guest_serial:-none}
--- restore ---
${restore_err}"
        send_ntfy "Watchdog ${i}" "${body}"
        if [ -f "${CHECKPOINT_DIR}/step3_verification.txt" ]; then
            send_ntfy "STEP 3 VERIFIED IN VM!" "$(cat "${CHECKPOINT_DIR}/step3_verification.txt")"
            break
        fi
        sleep 10
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
touch "${CHECKPOINT_DIR}/helper_done"

# If Step 3 was not verified and QEMU exited, cancel orphaned T9 workflow (not smoke/R9).
if [ "${T9_CANCEL_ON_QEMU_EXIT:-1}" = "1" ] && [ ! -f "${CHECKPOINT_DIR}/step3_verification.txt" ] && [ -n "${GITHUB_RUN_ID:-}" ] && [ "${GITHUB_RUN_ID}" != "0" ]; then
    log "Migration did not complete before QEMU exit. Cancelling orphaned workflow run ${GITHUB_RUN_ID}..."
    send_ntfy "Workflow Auto-Cancel" "Cancelling run ${GITHUB_RUN_ID} because QEMU exited (RC=${QEMU_RC}) without completing Step 3"
    gh run cancel "${GITHUB_RUN_ID}" 2>/dev/null || true
fi

log "=== Checkpoint Helper Completed ==="
exit 0
