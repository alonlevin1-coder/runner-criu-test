#!/usr/bin/env bash
# Live-streaming smoke: print immediately, then block so UI can update before step ends.
set -euo pipefail

PIPE="${LIVE_LOG_PIPE:-${RUNNER_VM_CHECKPOINT:-checkpoint}/live.pipe}"
SLEEP_SEC="${LIVE_ECHO_SLEEP_SEC:-30}"

if [ -p "${PIPE}" ]; then
    exec > >(stdbuf -oL tee "${PIPE}") 2>&1
fi

echo "lalala"
echo "live_echo pid=$$ kernel=$(uname -r) host=$(hostname)"
echo "sleeping ${SLEEP_SEC}s (output above should appear immediately in GHA UI)"
sleep "${SLEEP_SEC}"
echo "live_echo done"
