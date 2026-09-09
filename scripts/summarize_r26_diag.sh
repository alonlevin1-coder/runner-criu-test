#!/usr/bin/env bash
# Print R26 _diag investigation summary from checkpoint artifacts.
set -euo pipefail

CP="${RUNNER_VM_CHECKPOINT:-checkpoint}"
CP="$(cd "${CP}" 2>/dev/null && pwd || echo "${CP}")"

echo "=== R26 diag timeline (JobServerQueue / websocket grep) ==="
if [ -f "${CP}/r26_diag_timeline.txt" ]; then
    cat "${CP}/r26_diag_timeline.txt"
else
    echo "missing ${CP}/r26_diag_timeline.txt"
fi

echo ""
echo "=== snapshot dirs ==="
ls -la "${CP}/vm_diag/" 2>/dev/null || echo "no vm_diag/"

echo ""
echo "=== key patterns in final Worker log ==="
WORKER_LOG="$(find "${CP}/vm_diag" -name 'Worker*.log' 2>/dev/null | sort | tail -n 1 || true)"
if [ -n "${WORKER_LOG}" ] && [ -f "${WORKER_LOG}" ]; then
    echo "file: ${WORKER_LOG}"
    grep -E 'JobServerQueue|ResultServer|websocket|WebSocket|web console|Try to append|Stop aggressive|Successfully started|Failed|ERROR' \
        "${WORKER_LOG}" | tail -n 80 || echo "(no matches)"
else
    echo "no Worker*.log in vm_diag snapshots"
fi

[ -f "${CP}/r26_live_diag_done" ] || exit 1
