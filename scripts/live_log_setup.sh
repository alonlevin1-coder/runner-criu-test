#!/usr/bin/env bash
# Start a log forwarder outside the Worker freeze tree before migration dump.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CP="${RUNNER_VM_CHECKPOINT:-checkpoint}"
CP="$(mkdir -p "${CP}" && cd "${CP}" && pwd)"
PIPE="${CP}/live.pipe"

rm -f "${PIPE}"
mkfifo "${PIPE}"
chmod 666 "${PIPE}" 2>/dev/null || true

export LIVE_LOG_PIPE="${PIPE}"
echo "[live_log_setup] fifo=${PIPE} step_pid=$$"

if [ ! -x "${SCRIPT_DIR}/daemonize" ]; then
    gcc -O2 -Wall "${SCRIPT_DIR}/daemonize.c" -o "${SCRIPT_DIR}/daemonize"
fi

sudo -E "${SCRIPT_DIR}/daemonize" \
    bash "${SCRIPT_DIR}/live_log_forwarder.sh" "$$" "${PIPE}"

echo "[live_log_setup] forwarder launched (detached from Worker tree)"
