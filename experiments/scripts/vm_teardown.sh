#!/usr/bin/env bash
# Stop kept-alive QEMU after post-migration steps finish.
set -euo pipefail

CP="${RUNNER_VM_CHECKPOINT:-checkpoint}"
PIDFILE="${CP}/qemu.pid"

[ -f "${PIDFILE}" ] || exit 0
QPID="$(cat "${PIDFILE}" 2>/dev/null || true)"
[ -n "${QPID}" ] || exit 0

if kill -0 "${QPID}" 2>/dev/null; then
    echo "Stopping QEMU pid=${QPID}"
    kill -9 "${QPID}" 2>/dev/null || sudo kill -9 "${QPID}" 2>/dev/null || true
    wait "${QPID}" 2>/dev/null || true
fi

echo "qemu_teardown=yes" >> "${CP}/state.txt" 2>/dev/null || true
