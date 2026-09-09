#!/usr/bin/env bash
# Dump target with --leave-running, restore in QEMU via SSH + t9_restore (/tmp/is_vm).
set -euo pipefail

TARGET_PID="${1:?pid to dump}"
CHECKPOINT_DIR="${2:?checkpoint dir}"
REPO_DIR="${3:?repo dir}"
SERIAL_LOG="${4:?serial log}"
TARGET_KIND="${5:-dummy}"

CHECKPOINT_DIR="$(cd "${CHECKPOINT_DIR}" && pwd)"
REPO_DIR="$(cd "${REPO_DIR}" && pwd)"
HELPER_LOG="${CHECKPOINT_DIR}/is_vm_helper.log"
SSH_PORT="${SSH_PORT:-2222}"
SSH_KEY="${REPO_DIR}/appliance/ssh_id_ed25519"
KERNEL_BIN="${REPO_DIR}/appliance/bzImage"
INITRD_BIN="${REPO_DIR}/appliance/initramfs.cpio.gz"
NTFY_TOPIC="runner-criu-debug-morsho-test"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=freeze_snapshot_files.sh
source "${SCRIPT_DIR}/freeze_snapshot_files.sh"
CRIU_TCP_FLAG="$("${SCRIPT_DIR}/criu_tcp_flags.sh")"
CRIU_TCP_MODE="${CRIU_TCP_MODE:-close}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [is_vm] $*" | tee -a "${HELPER_LOG}"; }

host_tree_already_unfrozen() {
    [ -f "${CHECKPOINT_DIR}/state.txt" ] \
        && grep -q 'host_tree_unfrozen=yes' "${CHECKPOINT_DIR}/state.txt" 2>/dev/null
}

finalize_host_tree() {
    if [ ! -f "${CHECKPOINT_DIR}/sigstopped_pids.txt" ]; then
        return 0
    fi
    if [ -f "${CHECKPOINT_DIR}/vm_done" ] \
        && grep -qE 'tag=vm_(entry|loop|branch)' "${CHECKPOINT_DIR}/vm_done" 2>/dev/null \
        && [ "${KILL_HOST_WORKER_AFTER_MIGRATE:-0}" = "1" ]; then
        log "VM owns continuation — stopping host Worker tree"
        while read -r pid; do
            [ -n "${pid}" ] || continue
            kill -9 "${pid}" 2>/dev/null || sudo kill -9 "${pid}" 2>/dev/null || true
        done < "${CHECKPOINT_DIR}/sigstopped_pids.txt"
        echo "host_worker_stopped=yes" >> "${CHECKPOINT_DIR}/state.txt"
        return 0
    fi
    if host_tree_already_unfrozen; then
        log "host tree already unfrozen (migrator_ok branch path)"
        return 0
    fi
    log "SIGCONT host tree after VM restore window"
    unfreeze_tree "${CHECKPOINT_DIR}"
}
trap finalize_host_tree EXIT

send_ntfy() {
    local title="${1:-is_vm}"
    local msg="${2:-}"
    printf '%s' "${msg}" | curl -s --max-time 10 -H "Title: ${title}" --data-binary @- \
        "https://ntfy.sh/${NTFY_TOPIC}" 2>/dev/null || true
}

CMDLINE=$(tr '\0' ' ' < "/proc/${TARGET_PID}/cmdline" 2>/dev/null || true)
log "target kind=${TARGET_KIND} pid=${TARGET_PID} cmd=${CMDLINE}"

if [ "${TARGET_KIND}" = "dummy" ]; then
    if echo "${CMDLINE}" | grep -qE 'Runner\.(Listener|Worker)'; then
        log "REFUSING Runner.* for dummy dump"
        exit 2
    fi
elif [ "${TARGET_KIND}" = "worker" ]; then
    if ! echo "${CMDLINE}" | grep -q 'Runner\.Worker'; then
        log "REFUSING non-Worker for worker dump"
        exit 2
    fi
    if [ "${ALLOW_WORKER_DUMP:-0}" != "1" ]; then
        log "Set ALLOW_WORKER_DUMP=1 for Worker dump"
        exit 2
    fi
else
    log "unknown TARGET_KIND=${TARGET_KIND}"
    exit 2
fi

STEP2_READY="${CHECKPOINT_DIR}/step2_ready"
WAIT_LOOP_READY="${CHECKPOINT_DIR}/wait_loop_ready"
WAIT=0
while [ ! -f "${STEP2_READY}" ] && [ ! -f "${WAIT_LOOP_READY}" ]; do
    sleep 0.2
    WAIT=$((WAIT + 1))
    [ "${WAIT}" -le 300 ] || exit 1
done
log "dump gate open (step2_ready=$([ -f "${STEP2_READY}" ] && echo yes || echo no) wait_loop_ready=$([ -f "${WAIT_LOOP_READY}" ] && echo yes || echo no))"

mkdir -p "${CHECKPOINT_DIR}/dev_shm" "${CHECKPOINT_DIR}/host_tmp"
cp -a /dev/shm/* "${CHECKPOINT_DIR}/dev_shm/" 2>/dev/null || true
find /tmp -maxdepth 2 -user "$(id -u)" -exec cp -a {} "${CHECKPOINT_DIR}/host_tmp/" 2>/dev/null \; || true
log "saved dev_shm and host_tmp snapshots for guest restore"

if [ "${TARGET_KIND}" = "worker" ]; then
    {
        echo "=== worker fd summary pid=${TARGET_PID} ==="
        ls -la "/proc/${TARGET_PID}/fd/" 2>/dev/null | head -n 80 || true
        echo "=== worker maps (runner/dotnet/unix) ==="
        grep -E 'Runner|dotnet|pipe|socket|anon_inode' "/proc/${TARGET_PID}/maps" 2>/dev/null | head -n 40 || true
        echo "=== pgrep Worker/Listener ==="
        pgrep -af 'Runner\.(Worker|Listener)' 2>/dev/null || true
    } > "${CHECKPOINT_DIR}/worker_pre_dump.txt"
fi

echo "TARGET_KIND=${TARGET_KIND} TARGET_PID=${TARGET_PID}" >> "${CHECKPOINT_DIR}/state.txt"
CRIU_BIN="$(command -v criu || true)"
[ -x /usr/sbin/criu ] && CRIU_BIN="/usr/sbin/criu"

if [ "${TARGET_KIND}" = "worker" ]; then
    log "SIGSTOP worker tree before snapshot+dump"
    freeze_tree "${CHECKPOINT_DIR}" "${TARGET_PID}"
    log "snapshotting open regular files to frozen_files/"
    snapshot_open_files "${CHECKPOINT_DIR}" "${TARGET_PID}"
    if [ -f "${CHECKPOINT_DIR}/frozen_files/manifest.tsv" ]; then
        wc -l "${CHECKPOINT_DIR}/frozen_files/manifest.tsv" | tee -a "${HELPER_LOG}" || true
        tail -n 5 "${CHECKPOINT_DIR}/frozen_files/manifest.tsv" | tee -a "${HELPER_LOG}" || true
    fi
fi

echo "criu_tcp_mode=${CRIU_TCP_MODE}" >> "${CHECKPOINT_DIR}/state.txt"
echo "${CRIU_TCP_MODE}" > "${CHECKPOINT_DIR}/criu_tcp_mode.txt"
chmod a+rw "${CHECKPOINT_DIR}/criu_tcp_mode.txt" 2>/dev/null || true
log "criu dump --leave-running pid=${TARGET_PID} tcp=${CRIU_TCP_FLAG}"
"${SCRIPT_DIR}/load_criu_tcp_modules.sh"
set +e
sudo "${CRIU_BIN}" dump \
    -t "${TARGET_PID}" \
    -D "${CHECKPOINT_DIR}" \
    --leave-running \
    --shell-job --file-locks --ext-unix-sk "${CRIU_TCP_FLAG}" \
    --ghost-limit 32M \
    -v4 -o dump.log
DUMP_RC=$?
set -e
echo "${DUMP_RC}" > "${CHECKPOINT_DIR}/dump.rc"
log "dump rc=${DUMP_RC} leave_running=yes"
send_ntfy "is_vm dump" "kind=${TARGET_KIND} rc=${DUMP_RC} leave_running=1"

if [ "${DUMP_RC}" -ne 0 ]; then
    touch "${CHECKPOINT_DIR}/helper_failed"
    exit "${DUMP_RC}"
fi

if [ "${TARGET_KIND}" = "worker" ] \
    && [ "${CRIU_TCP_MODE}" = "established" ] \
    && [ "${ISOLATE_HOST_TCP_AFTER_DUMP:-1}" = "1" ]; then
    log "killing host TCP sockets after tcp-established dump (tree still frozen)"
    close_tree_tcp_sockets "${CHECKPOINT_DIR}"
fi

if ! kill -0 "${TARGET_PID}" 2>/dev/null; then
    log "WARN: target died despite --leave-running"
    echo "target_dead_after_dump=yes" >> "${CHECKPOINT_DIR}/state.txt"
else
    log "target still alive on host after leave-running dump (still frozen until restore done)"
    echo "target_alive_after_dump=yes" >> "${CHECKPOINT_DIR}/state.txt"
fi

RUNNER_HOME="/home/runner"
[ -d "${RUNNER_HOME}" ] || RUNNER_HOME="${HOME}"
DOTNET_DIR="/usr/share/dotnet"
[ -d "${DOTNET_DIR}" ] || DOTNET_DIR="/tmp"
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL_ARGS="-enable-kvm -cpu host"
else
    ACCEL_ARGS="-accel tcg -cpu max"
fi

: > "${SERIAL_LOG}"
chmod 666 "${SERIAL_LOG}" 2>/dev/null || true
log "booting QEMU for SSH restore"

VIRTFS_ARGS=(
    -virtfs "local,path=${RUNNER_HOME},mount_tag=host_runner,security_model=none,id=host_runner"
    -virtfs "local,path=/tmp,mount_tag=host_tmp,security_model=none,id=host_tmp"
    -virtfs "local,path=/usr/lib/x86_64-linux-gnu,mount_tag=usrlib,security_model=none,id=usrlib"
    -virtfs "local,path=${DOTNET_DIR},mount_tag=dotnet,security_model=none,id=dotnet"
    -virtfs "local,path=${CHECKPOINT_DIR},mount_tag=checkpoint,security_model=none,id=checkpoint"
)
for spec in "host_usr:/usr" "host_bin:/bin" "host_lib:/lib" "host_lib64:/lib64"; do
    tag="${spec%%:*}"
    path="${spec##*:}"
    if [ -d "${path}" ]; then
        VIRTFS_ARGS+=(-virtfs "local,path=${path},mount_tag=${tag},security_model=none,id=${tag}")
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
    -serial "file:${SERIAL_LOG}" >> "${HELPER_LOG}" 2>&1 &
QEMU_PID=$!
set -e
echo "${QEMU_PID}" > "${CHECKPOINT_DIR}/qemu.pid"

SSH=(ssh -i "${SSH_KEY}" -p "${SSH_PORT}" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -o BatchMode=yes root@127.0.0.1)

SSH_OK=0
for i in $(seq 1 90); do
    if "${SSH[@]}" 'echo SSH_OK' >/dev/null 2>> "${HELPER_LOG}"; then
        SSH_OK=1
        break
    fi
    kill -0 "${QEMU_PID}" 2>/dev/null || break
    sleep 1
done

if [ "${SSH_OK}" -ne 1 ]; then
    log "ssh failed"
    touch "${CHECKPOINT_DIR}/ssh_failed"
    kill -9 "${QEMU_PID}" 2>/dev/null || true
    touch "${CHECKPOINT_DIR}/helper_failed"
    exit 1
fi

log "running t9_restore.sh"
set +e
"${SSH[@]}" '/usr/sbin/t9_restore.sh' >> "${HELPER_LOG}" 2>&1
RESTORE_RC=$?
set -e
echo "${RESTORE_RC}" > "${CHECKPOINT_DIR}/restore.rc"
log "restore rc=${RESTORE_RC}"

if [ -f "${CHECKPOINT_DIR}/post_restore_diag.txt" ]; then
    log "post-restore diag:"
    tail -n 40 "${CHECKPOINT_DIR}/post_restore_diag.txt" | tee -a "${HELPER_LOG}" || true
fi
if [ -f "${CHECKPOINT_DIR}/vm_done" ]; then
    log "vm_done after restore: $(cat "${CHECKPOINT_DIR}/vm_done")"
fi
if [ -f "${CHECKPOINT_DIR}/migrator_ok" ]; then
    log "migrator_ok after restore: $(cat "${CHECKPOINT_DIR}/migrator_ok")"
fi

if [ -f "${CHECKPOINT_DIR}/restore_log.txt" ]; then
    grep -E 'Error|error|WARN|Failed|failed|spawn|unix|tcp|ghost|FPU|kerndat' \
        "${CHECKPOINT_DIR}/restore_log.txt" 2>/dev/null | tail -n 50 \
        > "${CHECKPOINT_DIR}/restore_errors.txt" || true
    log "restore errors: $(wc -l < "${CHECKPOINT_DIR}/restore_errors.txt" 2>/dev/null || echo 0) lines"
    tail -n 25 "${CHECKPOINT_DIR}/restore_errors.txt" 2>/dev/null | tee -a "${HELPER_LOG}" || true
fi
if [ -f "${CHECKPOINT_DIR}/dump.log" ]; then
    grep -E '^Error|error' "${CHECKPOINT_DIR}/dump.log" 2>/dev/null | tail -n 20 \
        > "${CHECKPOINT_DIR}/dump_errors.txt" || true
fi
ls -lh "${CHECKPOINT_DIR}"/*.img 2>/dev/null | tee -a "${HELPER_LOG}" || true

if [ "${RESTORE_RC}" -eq 0 ]; then
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    chmod -R a+rwX "${CHECKPOINT_DIR}" 2>/dev/null || true
    echo "migrator_ok ts=${TS} restore_rc=0" > "${CHECKPOINT_DIR}/migrator_ok"
    chmod a+rw "${CHECKPOINT_DIR}/migrator_ok" 2>/dev/null || true
    log "wrote migrator_ok — unfreezing host tree (host TCP already isolated after dump)"
    if [ -f "${CHECKPOINT_DIR}/sigstopped_pids.txt" ]; then
        unfreeze_tree "${CHECKPOINT_DIR}"
    fi
else
    log "restore failed (rc=${RESTORE_RC}) — not writing migrator_ok"
fi

for i in $(seq 1 60); do
    if [ -f "${CHECKPOINT_DIR}/vm_migrate_step_done" ]; then
        log "vm_migrate_step_done at ${i}s after migrator_ok"
        break
    fi
    if [ -f "${CHECKPOINT_DIR}/vm_done" ] \
        && grep -qE 'tag=vm_(entry|loop|branch)' "${CHECKPOINT_DIR}/vm_done" 2>/dev/null; then
        log "vm_done seen at ${i}s after migrator_ok"
        break
    fi
    sleep 1
done

if [ "${KEEP_QEMU_ALIVE:-0}" = "1" ]; then
    log "KEEP_QEMU_ALIVE=1 — leaving QEMU running pid=${QEMU_PID}"
    echo "qemu_keep_alive=yes" >> "${CHECKPOINT_DIR}/state.txt"
else
    kill -9 "${QEMU_PID}" 2>/dev/null || true
    wait "${QEMU_PID}" 2>/dev/null || true
fi
chmod -R a+rX "${CHECKPOINT_DIR}" "${SERIAL_LOG}" 2>/dev/null || true

if [ -f "${CHECKPOINT_DIR}/migrator_ok" ] && [ "${RESTORE_RC}" -eq 0 ]; then
    send_ntfy "is_vm OK" "$(cat "${CHECKPOINT_DIR}/migrator_ok")"
    touch "${CHECKPOINT_DIR}/helper_done"
elif [ -f "${CHECKPOINT_DIR}/vm_done" ] && [ "${RESTORE_RC}" -eq 0 ]; then
    send_ntfy "is_vm OK" "$(cat "${CHECKPOINT_DIR}/vm_done")"
    touch "${CHECKPOINT_DIR}/helper_done"
else
    send_ntfy "is_vm FAIL" "no migrator_ok restore_rc=${RESTORE_RC}"
    touch "${CHECKPOINT_DIR}/helper_failed"
    exit 1
fi
exit 0
