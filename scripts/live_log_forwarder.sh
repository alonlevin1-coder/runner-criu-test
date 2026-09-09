#!/usr/bin/env bash
# Detached from Runner.Worker tree — tails a FIFO into the GHA step stdout fd.
set -euo pipefail

STEP_PID="${1:?step pid}"
PIPE="${2:?fifo path}"
LOG="${PIPE%.pipe}/live_forwarder.log"

if [ ! -p "${PIPE}" ]; then
    echo "[live_log_forwarder] missing fifo: ${PIPE}" >> "${LOG}"
    exit 1
fi

OUT="/proc/${STEP_PID}/fd/1"
if [ ! -e "${OUT}" ]; then
    echo "[live_log_forwarder] missing ${OUT}" >> "${LOG}"
    exit 1
fi

if ! { echo "[live_log_forwarder] attached pid=${STEP_PID}" >> "${LOG}"; } 2>/dev/null; then
    : > "${LOG}" 2>/dev/null || true
fi

exec stdbuf -oL tail -f "${PIPE}" > "${OUT}" 2>> "${LOG}"
