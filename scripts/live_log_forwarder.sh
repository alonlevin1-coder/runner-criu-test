#!/usr/bin/env bash
# Detached from Runner.Worker tree — tails a FIFO into the GHA step stdout fd.
set -euo pipefail

STEP_PID="${1:?step pid}"
PIPE="${2:?fifo path}"

if [ ! -p "${PIPE}" ]; then
    echo "[live_log_forwarder] missing fifo: ${PIPE}" >&2
    exit 1
fi

if [ ! -r "/proc/${STEP_PID}/fd/1" ]; then
    echo "[live_log_forwarder] step pid ${STEP_PID} fd/1 not readable" >&2
    exit 1
fi

exec stdbuf -oL tail -f "${PIPE}" > "/proc/${STEP_PID}/fd/1"
