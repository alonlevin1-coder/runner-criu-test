#!/usr/bin/env bash
# Start a log forwarder outside the Worker freeze tree before migration dump.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CP="${RUNNER_VM_CHECKPOINT:-checkpoint}"
CP="$(mkdir -p "${CP}" && cd "${CP}" && pwd)"
LOG="${CP}/live.log"
STEP_PID="${1:-${LIVE_LOG_STEP_PID:-}}"

if [ -z "${STEP_PID}" ]; then
    echo "[live_log_setup] ERROR: pass GHA step bash pid as arg 1 (use: live_log_setup.sh \$\$)" >&2
    exit 1
fi

: > "${LOG}"
chmod 666 "${LOG}" 2>/dev/null || true

export LIVE_LOG_FILE="${LOG}"
echo "[live_log_setup] log=${LOG} step_pid=${STEP_PID}"

if [ ! -x "${SCRIPT_DIR}/daemonize" ]; then
    gcc -O2 -Wall "${SCRIPT_DIR}/daemonize.c" -o "${SCRIPT_DIR}/daemonize"
fi

# Same-user daemonize so we can write to the runner step stdout fd (not root).
"${SCRIPT_DIR}/daemonize" \
    bash "${SCRIPT_DIR}/live_log_forwarder.sh" "${STEP_PID}" "${LOG}"

echo "[live_log_setup] forwarder launched (detached from Worker tree)"
