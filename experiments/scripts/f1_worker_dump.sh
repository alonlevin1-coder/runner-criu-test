#!/usr/bin/env bash
# F1: Worker checkpoint on GHA — dump only, no QEMU/TAP/wait.
#
# Verifies we can freeze + criu dump Runner.Worker with the step shell excluded,
# then exit the workflow step cleanly with artifacts.
set -euo pipefail

CHECKPOINT_DIR="${1:-checkpoint}"
REPO_DIR="${2:-.}"
STEP_PID="${3:-$$}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKPOINT_DIR="$(mkdir -p "${CHECKPOINT_DIR}" && cd "${CHECKPOINT_DIR}" && pwd)"
REPO_DIR="$(cd "${REPO_DIR}" && pwd)"
LOG="${CHECKPOINT_DIR}/f1_worker_dump.log"
F1_UNFREEZE_AFTER_VERIFY="${F1_UNFREEZE_AFTER_VERIFY:-1}"

# shellcheck source=freeze_snapshot_files.sh
source "${SCRIPT_DIR}/freeze_snapshot_files.sh"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [f1] $*" | tee -a "${LOG}"; }

stage() {
    local name="${1:?}" detail="${2:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "${ts} f1_stage=${name} run=${GITHUB_RUN_ID:-0} pid=${STEP_PID} ${detail}" >> "${CHECKPOINT_DIR}/f1_stage.txt"
    log "stage=${name} ${detail}"
}

proc_state() {
    local pid="${1:?}"
    awk '/^State:/ {print $2; exit}' "/proc/${pid}/status" 2>/dev/null || echo "missing"
}

alive() {
    kill -0 "${1}" 2>/dev/null
}

find_worker_pid() {
    local pid
    pid="$(pgrep -f 'Runner\.Worker' | head -n1 || true)"
    if [ -n "${pid}" ]; then
        printf '%s' "${pid}"
        return 0
    fi
    return 1
}

write_pass() {
    local detail="${1:-}"
    date -u +%Y-%m-%dT%H:%M:%SZ > "${CHECKPOINT_DIR}/f1_pass.txt"
    [ -n "${detail}" ] && echo "${detail}" >> "${CHECKPOINT_DIR}/f1_pass.txt"
}

write_fail() {
    local detail="${1:-}"
    date -u +%Y-%m-%dT%H:%M:%SZ > "${CHECKPOINT_DIR}/f1_fail.txt"
    [ -n "${detail}" ] && echo "${detail}" >> "${CHECKPOINT_DIR}/f1_fail.txt"
}

on_fail() {
    local rc=$?
    write_fail "exit rc=${rc}"
    exit "${rc}"
}
trap on_fail ERR

: > "${LOG}"
echo "f1_start ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) step_pid=${STEP_PID}" > "${CHECKPOINT_DIR}/state.txt"
stage "start" "step_pid=${STEP_PID}"

WORKER_PID="${WORKER_PID:-}"
if [ -z "${WORKER_PID}" ]; then
    WORKER_PID="$(find_worker_pid)" || {
        write_fail "Runner.Worker not found"
        exit 1
    }
fi
echo "worker_pid=${WORKER_PID}" >> "${CHECKPOINT_DIR}/state.txt"
echo "${WORKER_PID}" > "${CHECKPOINT_DIR}/worker.pid"
stage "worker_found" "pid=${WORKER_PID}"

LISTENER_PID="$(pgrep -f 'Runner\.Listener' | head -n1 || true)"
echo "listener_pid=${LISTENER_PID:-none}" >> "${CHECKPOINT_DIR}/state.txt"

if [ -x "${SCRIPT_DIR}/map_workflow_processes.sh" ]; then
    "${SCRIPT_DIR}/map_workflow_processes.sh" "${CHECKPOINT_DIR}" "${STEP_PID}"
    stage "process_map" "done"
fi

echo "${STEP_PID}" > "${CHECKPOINT_DIR}/step_shell.pid"
echo "${STEP_PID}" > "${CHECKPOINT_DIR}/freeze_exclude_pids.txt"
chmod a+rw "${CHECKPOINT_DIR}/step_shell.pid" "${CHECKPOINT_DIR}/freeze_exclude_pids.txt" 2>/dev/null || true
stage "exclude" "step_shell=${STEP_PID}"

{
    echo "=== pre-dump Worker TCP ==="
    ss -H -tanp 2>/dev/null | grep -F "pid=${WORKER_PID}," || true
    echo "=== pre-dump eth0 ==="
    ip -o addr show dev eth0 2>/dev/null || true
} > "${CHECKPOINT_DIR}/f1_preflight.txt"

stage "freeze_start" "worker=${WORKER_PID}"
freeze_tree "${CHECKPOINT_DIR}" "${WORKER_PID}"
stage "freeze_ok" "count=$(wc -l < "${CHECKPOINT_DIR}/sigstopped_pids.txt" | tr -d ' ')"

stage "snapshot_start" ""
snapshot_open_files "${CHECKPOINT_DIR}" "${WORKER_PID}"
stage "snapshot_ok" "$(grep frozen_file_count "${CHECKPOINT_DIR}/state.txt" 2>/dev/null || true)"

CRIU_BIN="$(command -v criu || true)"
[ -x /usr/sbin/criu ] && CRIU_BIN="/usr/sbin/criu"
[ -n "${CRIU_BIN}" ] && [ -x "${CRIU_BIN}" ] || {
    write_fail "criu binary missing"
    exit 1
}

CRIU_TCP_FLAG="$("${SCRIPT_DIR}/criu_tcp_flags.sh")"
echo "criu_tcp_mode=${CRIU_TCP_MODE:-close}" >> "${CHECKPOINT_DIR}/state.txt"
echo "${CRIU_TCP_FLAG}" > "${CHECKPOINT_DIR}/criu_tcp_flag.txt"
stage "dump_start" "leave=--leave-stopped tcp=${CRIU_TCP_FLAG}"

"${SCRIPT_DIR}/load_criu_tcp_modules.sh"
stage "orchestrator_pause" "$(tr '\n' ' ' < "${CHECKPOINT_DIR}/freeze_exclude_pids.txt")"
orchestrator_pause_for_dump "${CHECKPOINT_DIR}"

set +e
sudo "${CRIU_BIN}" dump \
    -t "${WORKER_PID}" \
    -D "${CHECKPOINT_DIR}" \
    --leave-stopped \
    --shell-job --file-locks --ext-unix-sk "${CRIU_TCP_FLAG}" \
    --ghost-limit 32M \
    -v4 -o dump.log
DUMP_RC=$?
set -e

orchestrator_resume_after_dump "${CHECKPOINT_DIR}"
echo "${DUMP_RC}" > "${CHECKPOINT_DIR}/dump.rc"
stage "dump_done" "rc=${DUMP_RC}"

if [ "${DUMP_RC}" -ne 0 ]; then
    tail -n 30 "${CHECKPOINT_DIR}/dump.log" > "${CHECKPOINT_DIR}/dump_errors.txt" 2>/dev/null || true
    write_fail "dump.rc=${DUMP_RC}"
    exit "${DUMP_RC}"
fi

WORKER_STATE="$(proc_state "${WORKER_PID}")"
LISTENER_STATE="missing"
[ -n "${LISTENER_PID}" ] && LISTENER_STATE="$(proc_state "${LISTENER_PID}")"
STEP_STATE="$(proc_state "${STEP_PID}")"

{
    echo "worker_state=${WORKER_STATE}"
    echo "listener_state=${LISTENER_STATE}"
    echo "step_shell_state=${STEP_STATE}"
    echo "worker_alive=$(alive "${WORKER_PID}" && echo yes || echo no)"
    echo "listener_alive=$( [ -n "${LISTENER_PID}" ] && alive "${LISTENER_PID}" && echo yes || echo no)"
    echo "step_shell_alive=$(alive "${STEP_PID}" && echo yes || echo no)"
} > "${CHECKPOINT_DIR}/f1_post_dump_verify.txt"

stage "verify" "$(tr '\n' ' ' < "${CHECKPOINT_DIR}/f1_post_dump_verify.txt")"

FAIL_REASON=""
[ "${WORKER_STATE}" = "T" ] || FAIL_REASON="${FAIL_REASON} worker_not_stopped=${WORKER_STATE}"
[ -n "${LISTENER_PID}" ] && alive "${LISTENER_PID}" || FAIL_REASON="${FAIL_REASON} listener_dead"
alive "${STEP_PID}" || FAIL_REASON="${FAIL_REASON} step_shell_dead"
[ "${STEP_STATE}" != "T" ] || FAIL_REASON="${FAIL_REASON} step_shell_stopped"

if [ -n "${FAIL_REASON}" ]; then
    write_fail "${FAIL_REASON}"
    exit 1
fi

echo "step shell still runnable after dump"
echo "f1_step_echo_ok ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${CHECKPOINT_DIR}/f1_step_echo.txt"

if [ "${F1_UNFREEZE_AFTER_VERIFY}" = "1" ] && [ -f "${CHECKPOINT_DIR}/sigstopped_pids.txt" ]; then
    stage "unfreeze_for_job_completion" ""
    unfreeze_tree "${CHECKPOINT_DIR}"
    echo "f1_unfreeze_after_verify=yes" >> "${CHECKPOINT_DIR}/state.txt"
fi

write_pass "dump.rc=0 worker=${WORKER_STATE} listener=${LISTENER_STATE} step=${STEP_STATE}"
stage "pass" "done"
log "F1 PASS"
exit 0
