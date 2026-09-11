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
chmod 600 "${SSH_KEY}" 2>/dev/null || true
KERNEL_BIN="${REPO_DIR}/appliance/bzImage"
INITRD_BIN="${REPO_DIR}/appliance/initramfs.cpio.gz"
NTFY_TOPIC="${NTFY_TOPIC:-runner-criu-r30-tap-morsho}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=freeze_snapshot_files.sh
source "${SCRIPT_DIR}/freeze_snapshot_files.sh"
CRIU_TCP_FLAG="$("${SCRIPT_DIR}/criu_tcp_flags.sh")"
CRIU_TCP_MODE="${CRIU_TCP_MODE:-close}"

HELPER_STAGE="${CHECKPOINT_DIR}/helper_stage.txt"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [is_vm] $*" | tee -a "${HELPER_LOG}"; }

# Enable Docker socket proxy for microVM if Docker daemon is running on host
if [ -S /var/run/docker.sock ] && command -v socat >/dev/null 2>&1; then
    if ! pgrep -f 'TCP-LISTEN:2375' >/dev/null 2>&1; then
        nohup socat TCP-LISTEN:2375,bind=0.0.0.0,reuseaddr,fork UNIX-CONNECT:/var/run/docker.sock >/dev/null 2>&1 &
        disown || true
        log "Enabled persistent Docker daemon proxy on 0.0.0.0:2375"
    fi
fi

stage_mark() {
    local stage="${1:?stage}"
    local detail="${2:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "${ts} stage=${stage} run=${GITHUB_RUN_ID:-0} pid=$$ ${detail}" >> "${HELPER_STAGE}"
    printf '%s %s %s\n' "${ts}" "${stage}" "${detail}" > "${CHECKPOINT_DIR}/helper_stage_latest.txt"
    chmod a+rw "${HELPER_STAGE}" "${CHECKPOINT_DIR}/helper_stage_latest.txt" "${HELPER_LOG}" 2>/dev/null || true
}

run_with_timeout() {
    local sec="${1:?seconds}"
    shift
    local rc=0
    stage_mark "timeout_start" "sec=${sec} cmd=$*"
    if timeout "${sec}" "$@"; then
        stage_mark "timeout_ok" "sec=${sec} cmd=$*"
        return 0
    else
        rc=$?
        stage_mark "timeout_fail" "sec=${sec} rc=${rc} cmd=$*"
        return "${rc}"
    fi
}

upload_debug_snapshot() {
    if [ -x "${SCRIPT_DIR}/upload_checkpoint_debug.sh" ]; then
        UPLOAD_DEBUG_BRANCH="${UPLOAD_DEBUG_BRANCH:-0}" \
            "${SCRIPT_DIR}/upload_checkpoint_debug.sh" \
            "${CHECKPOINT_DIR}" "${REPO_DIR}" "R30" || true
    fi
}

host_tree_already_unfrozen() {
    [ -f "${CHECKPOINT_DIR}/state.txt" ] \
        && grep -q 'host_tree_unfrozen=yes' "${CHECKPOINT_DIR}/state.txt" 2>/dev/null
}

finalize_host_tree() {
    if [ ! -f "${CHECKPOINT_DIR}/sigstopped_pids.txt" ]; then
        return 0
    fi
    if [ -f "${CHECKPOINT_DIR}/state.txt" ] \
        && grep -qE 'host_tree_frozen_forever=yes|host_tree_killed=yes|host_worker_killed=yes' \
            "${CHECKPOINT_DIR}/state.txt" 2>/dev/null; then
        log "host tree must stay frozen (GHA tcp-established) — skip unfreeze"
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
    if [ "${CRIU_TCP_MODE}" = "established" ]; then
        log "tcp-established mode — never unfreeze host tree"
        return 0
    fi
    log "SIGCONT host tree after VM restore window"
    unfreeze_tree "${CHECKPOINT_DIR}"
}
send_ntfy() {
    local title="${1:-is_vm}"
    local msg="${2:-}"
    if [ "${#msg}" -gt 1800 ]; then
        msg="$(printf '%s' "${msg}" | tail -c 1800)"
    fi
    printf '%s' "${msg}" | curl -s --max-time 10 -H "Title: ${title}" --data-binary @- \
        "https://ntfy.sh/${NTFY_TOPIC}" 2>/dev/null || true
}

watchdog_sample() {
    local label="${1:-sample}"
    chmod -R a+rX "${CHECKPOINT_DIR}" "${SERIAL_LOG}" 2>/dev/null || true
    local serial_sz qemu_alive progress guest_serial restore_err state_snip
    serial_sz=$(wc -c < "${SERIAL_LOG}" 2>/dev/null | tr -d ' ' || echo 0)
    qemu_alive=no
    [ -n "${QEMU_PID:-}" ] && kill -0 "${QEMU_PID}" 2>/dev/null && qemu_alive=yes
    progress="$(cat "${CHECKPOINT_DIR}/guest_progress.txt" 2>/dev/null || echo "(no guest_progress.txt)")"
    guest_serial="$(grep -E '\[GUEST\]|QEMU Guest VM Booted|CRIU restore returned|network_reconstruct' \
        "${SERIAL_LOG}" 2>/dev/null | tail -n 12 || true)"
    restore_err="$(grep -E 'Error \(|error|Failed|failed|tcp|ghost|FPU' \
        "${CHECKPOINT_DIR}/restore_log.txt" 2>/dev/null | tail -n 8 || echo "(no restore log)")"
    state_snip="$(grep -E 'host_tap|host_tree|migrator|target_|criu_tcp|host_blocked' \
        "${CHECKPOINT_DIR}/state.txt" 2>/dev/null | tail -n 8 || true)"
    {
        echo "t=$(date -u +%H:%M:%S) label=${label} qemu=${qemu_alive} serial_bytes=${serial_sz} run=${GITHUB_RUN_ID:-0}"
        echo "${progress}" | tail -n 6
        echo "--- state ---"
        echo "${state_snip:-none}"
        echo "---"
    } >> "${CHECKPOINT_DIR}/host_watchdog.txt"
    send_ntfy "is_vm [${label}]" "run=${GITHUB_RUN_ID:-0} qemu=${qemu_alive} serial_bytes=${serial_sz}
--- progress ---
$(printf '%s' "${progress}" | tail -n 8)
--- guest ---
${guest_serial:-none}
--- restore ---
${restore_err}
--- state ---
${state_snip:-none}"
}

start_watchdog() {
    local max_iter="${1:-12}"
    (
        set +e
        sleep 8
        for i in $(seq 1 "${max_iter}"); do
            watchdog_sample "wd${i}"
            [ -f "${CHECKPOINT_DIR}/helper_done" ] || [ -f "${CHECKPOINT_DIR}/helper_failed" ] && break
            [ -f "${CHECKPOINT_DIR}/migrator_ok" ] \
                && [ -f "${CHECKPOINT_DIR}/vm_migrate_step_done" ] && break
            sleep 10
        done
    ) &
    WATCHDOG_PID=$!
}

stop_watchdog() {
    [ -n "${WATCHDOG_PID:-}" ] && kill "${WATCHDOG_PID}" 2>/dev/null || true
}
on_exit() {
    stop_watchdog
    stage_mark "helper_exit" "rc=${HELPER_EXIT_RC:-0}"
    upload_debug_snapshot
    finalize_host_tree
}
trap on_exit EXIT
HELPER_EXIT_RC=0

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
stage_mark "started" "kind=${TARGET_KIND} target_pid=${TARGET_PID} tcp_mode=${CRIU_TCP_MODE}"
send_ntfy "is_vm Started" "run=${GITHUB_RUN_ID:-0} kind=${TARGET_KIND} pid=${TARGET_PID} tcp_mode=${CRIU_TCP_MODE} tcp_flag=${CRIU_TCP_FLAG}"

mkdir -p "${CHECKPOINT_DIR}/dev_shm" "${CHECKPOINT_DIR}/host_tmp"
cp -a /dev/shm/* "${CHECKPOINT_DIR}/dev_shm/" 2>/dev/null || true
find /tmp -mindepth 1 -maxdepth 1 -user "$(id -u)" ! -name "runner_*" -exec cp -a {} "${CHECKPOINT_DIR}/host_tmp/" 2>/dev/null \; || true
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
    stage_mark "freeze_start" "pid=${TARGET_PID}"
    freeze_tree "${CHECKPOINT_DIR}" "${TARGET_PID}"
    stage_mark "freeze_ok" "count=$(wc -l < "${CHECKPOINT_DIR}/sigstopped_pids.txt" 2>/dev/null || echo 0)"
    log "snapshotting open regular files to frozen_files/"
    snapshot_open_files "${CHECKPOINT_DIR}" "${TARGET_PID}"
    if [ -f "${CHECKPOINT_DIR}/frozen_files/manifest.tsv" ]; then
        wc -l "${CHECKPOINT_DIR}/frozen_files/manifest.tsv" | tee -a "${HELPER_LOG}" || true
        tail -n 5 "${CHECKPOINT_DIR}/frozen_files/manifest.tsv" | tee -a "${HELPER_LOG}" || true
    fi
fi

if [ "${TARGET_KIND}" = "worker" ] && [ "${CRIU_TCP_MODE}" = "established" ]; then
    log "discover Worker established TCP local IPs while frozen (Porter F09)"
    stage_mark "tcp_discover_start" "pid=${TARGET_PID}"
    chmod +x "${SCRIPT_DIR}/discover_tcp_ips.sh"
    if ! run_with_timeout 60 "${SCRIPT_DIR}/discover_tcp_ips.sh" "${TARGET_PID}" "${CHECKPOINT_DIR}"; then
        log "ERROR: tcp discover failed or timed out"
        send_ntfy "is_vm FAIL" "tcp discover timeout/fail"
        touch "${CHECKPOINT_DIR}/helper_failed"
        HELPER_EXIT_RC=1
        exit 1
    fi
    if [ ! -s "${CHECKPOINT_DIR}/tcp_local_ips.txt" ]; then
        log "ERROR: established mode requires non-loopback ESTAB socket local IP"
        send_ntfy "is_vm FAIL" "tcp discover: no local IP in tcp_local_ips.txt"
        touch "${CHECKPOINT_DIR}/helper_failed"
        HELPER_EXIT_RC=1
        exit 1
    fi
    stage_mark "tcp_discover_ok" "ips=$(head -n1 "${CHECKPOINT_DIR}/tcp_local_ips.txt")"
    send_ntfy "is_vm TCP discover" "$(head -n 5 "${CHECKPOINT_DIR}/tcp_local_ips.txt" 2>/dev/null || true)
$(cat "${CHECKPOINT_DIR}/network_spec.env" 2>/dev/null || true)"
fi

if command -v ss >/dev/null 2>&1; then
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -u > "${CHECKPOINT_DIR}/host_ports.txt" 2>/dev/null || true
    chmod a+rw "${CHECKPOINT_DIR}/host_ports.txt" 2>/dev/null || true
fi

echo "criu_tcp_mode=${CRIU_TCP_MODE}" >> "${CHECKPOINT_DIR}/state.txt"
echo "${CRIU_TCP_MODE}" > "${CHECKPOINT_DIR}/criu_tcp_mode.txt"
chmod a+rw "${CHECKPOINT_DIR}/criu_tcp_mode.txt" 2>/dev/null || true
LEAVE_FLAG="--leave-running"
if [ "${CRIU_TCP_MODE}" = "established" ] && [ "${TARGET_KIND}" = "worker" ]; then
    LEAVE_FLAG="--leave-stopped"
fi
log "criu dump ${LEAVE_FLAG} pid=${TARGET_PID} tcp=${CRIU_TCP_FLAG}"
stage_mark "dump_start" "leave=${LEAVE_FLAG} tcp=${CRIU_TCP_FLAG}"
"${SCRIPT_DIR}/load_criu_tcp_modules.sh"
if [ -f "${CHECKPOINT_DIR}/freeze_exclude_pids.txt" ]; then
    log "pausing orchestrator PIDs for criu dump"
    stage_mark "orchestrator_pause" "$(tr '\n' ' ' < "${CHECKPOINT_DIR}/freeze_exclude_pids.txt")"
    orchestrator_pause_for_dump "${CHECKPOINT_DIR}"
fi
set +e
sudo "${CRIU_BIN}" dump \
    -t "${TARGET_PID}" \
    -D "${CHECKPOINT_DIR}" \
    "${LEAVE_FLAG}" \
    --shell-job --file-locks --ext-unix-sk "${CRIU_TCP_FLAG}" \
    --ghost-limit 32M \
    -v4 -o dump.log
DUMP_RC=$?
set -e
if [ -f "${CHECKPOINT_DIR}/freeze_exclude_pids.txt" ]; then
    orchestrator_resume_after_dump "${CHECKPOINT_DIR}"
    stage_mark "orchestrator_resume" "dump_rc=${DUMP_RC}"
    log "resumed orchestrator PIDs after criu dump"
fi
echo "${DUMP_RC}" > "${CHECKPOINT_DIR}/dump.rc"
log "dump rc=${DUMP_RC} ${LEAVE_FLAG}"
stage_mark "dump_done" "rc=${DUMP_RC} ${LEAVE_FLAG}"
send_ntfy "is_vm dump" "kind=${TARGET_KIND} rc=${DUMP_RC} ${LEAVE_FLAG}=1 run=${GITHUB_RUN_ID:-0}"

if [ "${DUMP_RC}" -ne 0 ]; then
    dump_tail="$(tail -n 25 "${CHECKPOINT_DIR}/dump.log" 2>/dev/null || true)"
    send_ntfy "is_vm dump FAIL" "rc=${DUMP_RC}
${dump_tail}"
    touch "${CHECKPOINT_DIR}/helper_failed"
    HELPER_EXIT_RC="${DUMP_RC}"
    exit "${DUMP_RC}"
fi

if [ "${TARGET_KIND}" = "worker" ] && [ "${CRIU_TCP_MODE}" = "established" ]; then
    # GHA constraint (R13): killing Worker tears down the hosted VM immediately.
    # Porter F09 step 13 (SIGKILL source tree) does NOT apply here — keep host
    # Worker alive but frozen (R14: suspend keeps Listener + VM up).
    log "tcp-established: host Worker stays frozen (no SIGKILL on GHA)"
    echo "host_tree_frozen_forever=yes" >> "${CHECKPOINT_DIR}/state.txt"
    if [ "${ISOLATE_HOST_TCP_AFTER_DUMP:-0}" = "1" ]; then
        log "closing host TCP sockets while tree frozen (ss -K)"
        stage_mark "tcp_close_start" ""
        if ! run_with_timeout "${TCP_CLOSE_TIMEOUT_SEC:-120}" "${SCRIPT_DIR}/host_close_tcp_sockets.sh" "${CHECKPOINT_DIR}"; then
            log "ERROR: tcp close timed out or failed"
            send_ntfy "is_vm FAIL" "tcp close timeout rc=$?"
            touch "${CHECKPOINT_DIR}/helper_failed"
            HELPER_EXIT_RC=1
            exit 1
        fi
        stage_mark "tcp_close_ok" "$(tail -n1 "${CHECKPOINT_DIR}/state.txt" 2>/dev/null || true)"
        send_ntfy "is_vm TCP close" "$(tail -n 15 "${CHECKPOINT_DIR}/host_tcp_close.log" 2>/dev/null || echo done)"
    else
        log "skipping ss -K (host Worker stays frozen; VM copy owns TCP for now)"
        echo "host_tcp_sockets_closed=skipped reason=frozen_host_no_isolate" \
            >> "${CHECKPOINT_DIR}/state.txt"
        stage_mark "tcp_close_skip" "frozen_host"
    fi
    chmod +x "${SCRIPT_DIR}/host_tap_cutover.sh"
    stage_mark "tap_start" ""
    if ! run_with_timeout "${TAP_CUTOVER_TIMEOUT_SEC:-120}" "${SCRIPT_DIR}/host_tap_cutover.sh" "${CHECKPOINT_DIR}"; then
        log "ERROR: host TAP cutover failed or timed out"
        send_ntfy "is_vm TAP FAIL" "$(tail -n 20 "${CHECKPOINT_DIR}/host_tap_cutover.log" 2>/dev/null || true)"
        touch "${CHECKPOINT_DIR}/helper_failed"
        HELPER_EXIT_RC=1
        exit 1
    fi
    stage_mark "tap_ok" "net_mode=$(cat "${CHECKPOINT_DIR}/net_mode.txt" 2>/dev/null || echo unknown)"
    send_ntfy "is_vm TAP OK" "$(tail -n 15 "${CHECKPOINT_DIR}/host_tap_cutover.log" 2>/dev/null || true)
net_mode=$(cat "${CHECKPOINT_DIR}/net_mode.txt" 2>/dev/null || echo unknown)"
elif ! kill -0 "${TARGET_PID}" 2>/dev/null; then
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
NET_MODE="user"
[ -f "${CHECKPOINT_DIR}/net_mode.txt" ] && NET_MODE="$(cat "${CHECKPOINT_DIR}/net_mode.txt")"
log "booting QEMU for SSH restore net_mode=${NET_MODE}"
stage_mark "qemu_start" "net_mode=${NET_MODE} ssh_port=${SSH_PORT}"
send_ntfy "is_vm Booting QEMU" "run=${GITHUB_RUN_ID:-0} accel=${ACCEL_ARGS} net_mode=${NET_MODE} ssh_port=${SSH_PORT}"

VIRTFS_ARGS=(
    -virtfs "local,path=/,mount_tag=host_root,security_model=none,readonly=on,id=host_root"
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
        VIRTFS_ARGS+=(-virtfs "local,path=${path},mount_tag=${tag},security_model=none,id=${tag}")
    fi
done

NETDEV_ARGS=()
if [ -f "${CHECKPOINT_DIR}/net_mode.txt" ] \
    && [ "$(cat "${CHECKPOINT_DIR}/net_mode.txt")" = "tap" ] \
    && [ -f "${CHECKPOINT_DIR}/network_spec.env" ]; then
    # shellcheck disable=SC1091
    source "${CHECKPOINT_DIR}/network_spec.env"
    log "QEMU dual-NIC: net0=tap(${TAP_DEV}) workload IP ${LOCAL_IP} mac=${ETH0_MAC:-auto}, net1=user SSH"
    DEV_NET0_ARG="virtio-net-pci,netdev=net0"
    if [ -n "${ETH0_MAC:-}" ]; then
        DEV_NET0_ARG="virtio-net-pci,netdev=net0,mac=${ETH0_MAC}"
    fi
    NETDEV_ARGS=(
        -netdev "tap,id=net0,ifname=${TAP_DEV},script=no,downscript=no"
        -device "${DEV_NET0_ARG}"
        -netdev "user,id=net1,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"
        -device "virtio-net-pci,netdev=net1"
    )
else
    NETDEV_ARGS=(
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"
        -device "virtio-net-pci,netdev=net0"
    )
fi

MEM_ARG="${QEMU_MEM:-2G}"
[[ "${MEM_ARG}" =~ ^[0-9]+$ ]] && MEM_ARG="${MEM_ARG}M"
SMP_ARG="${QEMU_SMP:-2}"

set +e
qemu-system-x86_64 \
    ${ACCEL_ARGS} -m "${MEM_ARG}" -smp "${SMP_ARG}" \
    -display none -monitor none \
    -kernel "${KERNEL_BIN}" \
    -initrd "${INITRD_BIN}" \
    -append "earlyprintk=ttyS0 console=ttyS0 panic=1 loglevel=7 net.ifnames=0 biosdevname=0 rdinit=/init" \
    -no-reboot \
    "${NETDEV_ARGS[@]}" \
    "${VIRTFS_ARGS[@]}" \
    -serial "file:${SERIAL_LOG}" >> "${HELPER_LOG}" 2>&1 &
QEMU_PID=$!
set -e
echo "${QEMU_PID}" > "${CHECKPOINT_DIR}/qemu.pid"
WATCHDOG_ITERS=12
[ "${KEEP_QEMU_ALIVE:-0}" = "1" ] && WATCHDOG_ITERS=36
start_watchdog "${WATCHDOG_ITERS}"
send_ntfy "is_vm QEMU pid" "pid=${QEMU_PID} serial_bytes=0 run=${GITHUB_RUN_ID:-0}"

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
    stage_mark "ssh_fail" "port=${SSH_PORT}"
    serial_sz=$(wc -c < "${SERIAL_LOG}" 2>/dev/null | tr -d ' ' || echo 0)
    send_ntfy "is_vm SSH FAIL" "port=${SSH_PORT} serial_bytes=${serial_sz} qemu_alive=$(kill -0 "${QEMU_PID}" 2>/dev/null && echo yes || echo no)
$(tail -n 15 "${HELPER_LOG}" 2>/dev/null || true)"
    touch "${CHECKPOINT_DIR}/ssh_failed"
    kill -9 "${QEMU_PID}" 2>/dev/null || true
    touch "${CHECKPOINT_DIR}/helper_failed"
    HELPER_EXIT_RC=1
    exit 1
fi

stage_mark "ssh_ok" "port=${SSH_PORT}"
send_ntfy "is_vm SSH Ready" "port=${SSH_PORT} running t9_restore.sh"
log "running t9_restore.sh"
stage_mark "restore_start" ""
set +e
run_with_timeout "${RESTORE_TIMEOUT_SEC:-300}" "${SSH[@]}" '/usr/sbin/t9_restore.sh' >> "${HELPER_LOG}" 2>&1
RESTORE_RC=$?
set -e
echo "${RESTORE_RC}" > "${CHECKPOINT_DIR}/restore.rc"
log "restore rc=${RESTORE_RC}"
stage_mark "restore_done" "rc=${RESTORE_RC}"
send_ntfy "is_vm Restore" "rc=${RESTORE_RC}
$(tail -n 20 "${CHECKPOINT_DIR}/restore_log.txt" 2>/dev/null || tail -n 20 "${HELPER_LOG}" 2>/dev/null || true)"

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
    stage_mark "migrator_ok" "restore_rc=0"

    # Activate TC redirect and remove CRIU drop rules now that guest sockets are restored
    if [ -x "${SCRIPT_DIR}/host_tap_activate.sh" ]; then
        log "running host_tap_activate.sh to enable TC redirect and remove DROP rules"
        "${SCRIPT_DIR}/host_tap_activate.sh" "${CHECKPOINT_DIR}" 2>&1 | tee -a "${HELPER_LOG}" || true
    fi

    if [ "${CRIU_TCP_MODE}" = "established" ]; then
        log "wrote migrator_ok — host Worker stays frozen (GHA: never kill/unfreeze)"
    else
        log "wrote migrator_ok — unfreezing host tree"
        if [ -f "${CHECKPOINT_DIR}/sigstopped_pids.txt" ]; then
            unfreeze_tree "${CHECKPOINT_DIR}"
        fi
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

if [ "${KEEP_QEMU_ALIVE:-0}" = "1" ] || [ "${TARGET_KIND}" = "worker" ]; then
    log "leaving QEMU running pid=${QEMU_PID} (target_kind=${TARGET_KIND})"
    echo "qemu_keep_alive=yes" >> "${CHECKPOINT_DIR}/state.txt"
else
    kill -9 "${QEMU_PID}" 2>/dev/null || true
    wait "${QEMU_PID}" 2>/dev/null || true
fi
chmod -R a+rX "${CHECKPOINT_DIR}" "${SERIAL_LOG}" 2>/dev/null || true

if [ -f "${CHECKPOINT_DIR}/migrator_ok" ] && [ "${RESTORE_RC}" -eq 0 ]; then
    send_ntfy "is_vm OK" "$(cat "${CHECKPOINT_DIR}/migrator_ok")"
    touch "${CHECKPOINT_DIR}/helper_done"
    stage_mark "helper_done" "migrator_ok"
elif [ -f "${CHECKPOINT_DIR}/vm_done" ] && [ "${RESTORE_RC}" -eq 0 ]; then
    send_ntfy "is_vm OK" "$(cat "${CHECKPOINT_DIR}/vm_done")"
    touch "${CHECKPOINT_DIR}/helper_done"
    stage_mark "helper_done" "vm_done"
else
    send_ntfy "is_vm FAIL" "no migrator_ok restore_rc=${RESTORE_RC} run=${GITHUB_RUN_ID:-0}
$(tail -n 12 "${CHECKPOINT_DIR}/restore_errors.txt" 2>/dev/null || true)
$(tail -n 8 "${CHECKPOINT_DIR}/guest_progress.txt" 2>/dev/null || true)"
    touch "${CHECKPOINT_DIR}/helper_failed"
    stage_mark "helper_fail" "restore_rc=${RESTORE_RC}"
    HELPER_EXIT_RC=1
    exit 1
fi
exit 0
