#!/usr/bin/env bash
# Detached from Runner.Worker tree — tails a FIFO into the GHA step stdout fd.
set -euo pipefail

STEP_PID="${1:?step pid}"
STREAM="${2:?log file path}"
LOG="${STREAM%/*}/live_forwarder.log"

if [ ! -f "${STREAM}" ]; then
    echo "[live_log_forwarder] missing log file: ${STREAM}" >> "${LOG}"
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

exec stdbuf -oL tail -F -n +0 "${STREAM}" > "${OUT}" 2>> "${LOG}"
