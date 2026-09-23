#!/usr/bin/env bash
set -euo pipefail

# scripts/fix_listener_fds.sh
# Inspects target PID and closes any problematic FDs (e.g. /dev/pts/*) via gdb

PID="${1:-}"

if [ -z "${PID}" ]; then
    echo "Usage: $0 <PID>"
    exit 1
fi

LOG_FILE="/tmp/fd_fix.log"
echo "=== FD Inspection & Sanitization for PID ${PID} at $(date) ===" | tee -a "${LOG_FILE}"

if [ ! -d "/proc/${PID}/fd" ]; then
    echo "[ERROR] /proc/${PID}/fd does not exist (process not running?)" | tee -a "${LOG_FILE}"
    exit 1
fi

echo "--- Pre-sanitization FDs for PID ${PID} ($(cat "/proc/${PID}/cmdline" 2>/dev/null | tr '\0' ' ' || echo "unknown")) ---" | tee -a "${LOG_FILE}"
ls -la "/proc/${PID}/fd/" | tee -a "${LOG_FILE}"

PTY_COUNT=0
for FD in $(ls -1 "/proc/${PID}/fd/" 2>/dev/null | sort -n); do
    TARGET=$(readlink "/proc/${PID}/fd/${FD}" 2>/dev/null || echo "")
    
    # Check for PTY descriptors
    if [[ "${TARGET}" == *"/dev/pts"* ]] || [[ "${TARGET}" == *"/dev/ptmx"* ]]; then
        echo "[FIX] Found PTY FD ${FD} -> ${TARGET} in PID ${PID}. Closing via gdb..." | tee -a "${LOG_FILE}"
        PTY_COUNT=$((PTY_COUNT + 1))
        sudo gdb -batch -p "${PID}" \
            -ex "call (int)close(${FD})" \
            -ex detach 2>&1 | tee -a "${LOG_FILE}"
    fi
done

if [ ${PTY_COUNT} -eq 0 ]; then
    echo "[OK] No PTY file descriptors found in PID ${PID}." | tee -a "${LOG_FILE}"
fi

echo "--- Post-sanitization FDs for PID ${PID} ---" | tee -a "${LOG_FILE}"
ls -la "/proc/${PID}/fd/" | tee -a "${LOG_FILE}"

echo "=== FD Inspection & Sanitization Complete ===" | tee -a "${LOG_FILE}"
exit 0
