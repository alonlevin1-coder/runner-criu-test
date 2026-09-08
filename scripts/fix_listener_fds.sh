#!/usr/bin/env bash
set -euo pipefail

# scripts/fix_listener_fds.sh
# Inspects target PID(s) and closes or redirects problematic FDs (e.g. /dev/pts/*)

TARGET_PIDS=("$@")

if [ ${#TARGET_PIDS[@]} -eq 0 ]; then
    echo "Usage: $0 <PID> [PID...]"
    exit 1
fi

LOG_FILE="/tmp/fd_fix.log"
echo "=== FD Inspection & Sanitization Started at $(date) ===" | tee -a "${LOG_FILE}"

for PID in "${TARGET_PIDS[@]}"; do
    if [ ! -d "/proc/${PID}/fd" ]; then
        echo "[WARN] /proc/${PID}/fd does not exist (process not running?)" | tee -a "${LOG_FILE}"
        continue
    fi

    echo "--- Inspecting PID ${PID} ($(cat "/proc/${PID}/cmdline" 2>/dev/null | tr '\0' ' ' || echo "unknown")) ---" | tee -a "${LOG_FILE}"
    
    # Iterate over open file descriptors
    for FD in $(ls -1 "/proc/${PID}/fd/" 2>/dev/null | sort -n); do
        TARGET=$(readlink "/proc/${PID}/fd/${FD}" 2>/dev/null || echo "")
        
        # Check for PTY descriptors
        if [[ "${TARGET}" == *"/dev/pts"* ]] || [[ "${TARGET}" == *"/dev/ptmx"* ]]; then
            echo "[FIX] Found PTY FD ${FD} -> ${TARGET} in PID ${PID}. Replacing with /dev/null via gdb..." | tee -a "${LOG_FILE}"
            sudo gdb -batch -p "${PID}" \
                -ex "call (int)dup2(open(\"/dev/null\", 2), ${FD})" \
                -ex detach 2>&1 | tee -a "${LOG_FILE}"
            NEW_TARGET=$(readlink "/proc/${PID}/fd/${FD}" 2>/dev/null || echo "closed")
            echo "[FIX] Result: FD ${FD} now points to: ${NEW_TARGET}" | tee -a "${LOG_FILE}"
        elif [[ "${TARGET}" == *"socket:"* ]] || [[ "${TARGET}" == *"dotnet-diagnostic"* ]]; then
            echo "[INFO] FD ${FD} is socket/diag: ${TARGET}" | tee -a "${LOG_FILE}"
        else
            echo "       FD ${FD} -> ${TARGET}" >> "${LOG_FILE}"
        fi
    done

    echo "--- Post-sanitization FDs for PID ${PID} ---" | tee -a "${LOG_FILE}"
    ls -la "/proc/${PID}/fd/" 2>/dev/null | tee -a "${LOG_FILE}"
done

echo "=== FD Inspection & Sanitization Complete ===" | tee -a "${LOG_FILE}"
exit 0
