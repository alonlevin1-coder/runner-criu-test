#!/usr/bin/env bash
# Live-streaming smoke: print immediately, then block so UI can update before step ends.
set -euo pipefail

CP="${RUNNER_VM_CHECKPOINT:-checkpoint}"
LOG="${LIVE_LOG_FILE:-${CP}/live.log}"
SLEEP_SEC="${LIVE_ECHO_SLEEP_SEC:-30}"

{
    echo "lalala"
    echo "live_echo pid=$$ kernel=$(uname -r) host=$(hostname)"
    echo "sleeping ${SLEEP_SEC}s (output above should appear immediately in GHA UI)"
    date -u +%Y-%m-%dT%H:%M:%SZ > "${CP}/live_echo_started.txt"
    sleep "${SLEEP_SEC}"
    echo "live_echo done"
    date -u +%Y-%m-%dT%H:%M:%SZ > "${CP}/live_echo_finished.txt"
} 2>&1 | stdbuf -oL tee -a "${LOG}"
