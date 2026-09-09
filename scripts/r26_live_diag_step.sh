#!/usr/bin/env bash
# Native VM step: echo lalala, periodic _diag snapshots while sleeping, final snapshot.
set -euo pipefail

CP="${RUNNER_VM_CHECKPOINT:-checkpoint}"
CP="$(mkdir -p "${CP}" && cd "${CP}" && pwd)"
SLEEP_SEC="${SLEEP_SEC:-120}"
INTERVAL="${DIAG_INTERVAL_SEC:-10}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f /tmp/is_vm ]; then
    echo "FAIL: R26 live diag step must run inside VM (/tmp/is_vm missing)"
    exit 1
fi

collector_loop() {
    local n=0
    while true; do
        n=$((n + 1))
        bash "${SCRIPT_DIR}/collect_runner_diag.sh" "during_sleep_${n}" || true
        sleep "${INTERVAL}"
    done
}

echo "=== R26 live diag step in VM ==="
bash "${SCRIPT_DIR}/collect_runner_diag.sh" "before_echo" || true

echo "lalala"
echo "pid=$$ kernel=$(uname -r) hostname=$(hostname)"
echo "sleeping ${SLEEP_SEC}s with diag snapshots every ${INTERVAL}s"
date -u +%Y-%m-%dT%H:%M:%SZ | tee "${CP}/r26_echo_started.txt"

bash "${SCRIPT_DIR}/collect_runner_diag.sh" "after_echo_before_sleep" || true

collector_loop &
COLLECTOR_PID=$!
trap 'kill "${COLLECTOR_PID}" 2>/dev/null || true' EXIT

sleep "${SLEEP_SEC}"

kill "${COLLECTOR_PID}" 2>/dev/null || true
wait "${COLLECTOR_PID}" 2>/dev/null || true
trap - EXIT

echo "r26_live_diag done"
date -u +%Y-%m-%dT%H:%M:%SZ > "${CP}/r26_echo_finished.txt"
bash "${SCRIPT_DIR}/collect_runner_diag.sh" "after_sleep" || true
touch "${CP}/r26_live_diag_done"
sync
