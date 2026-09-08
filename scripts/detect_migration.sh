#!/usr/bin/env bash
set -euo pipefail

# scripts/detect_migration.sh
# Runs inside Step 2. Signals readiness to helper and polls for migration into VM.

CHECKPOINT_DIR="${1:-./checkpoint}"
STEP2_READY="${CHECKPOINT_DIR}/step2_ready"

echo "=== [STEP 2] detect_migration.sh initiated ==="
echo "Initial Hostname: $(hostname)"
echo "Initial PID 1:    $(cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ' || echo "unknown")"
echo "Initial Kernel:   $(uname -r)"
INITIAL_HOST=$(hostname)
INITIAL_BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "none")

# Signal checkpoint helper that Step 2 is ready and settled
mkdir -p "${CHECKPOINT_DIR}"
touch "${STEP2_READY}"
echo "[STEP 2] Created readiness marker: ${STEP2_READY}"
echo "[STEP 2] Waiting for CRIU dump, QEMU boot, and VM restore..."

# Wait until migrated into VM
while true; do
    CUR_HOST=$(hostname)
    CUR_BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "none")

    if [ "${CUR_HOST}" != "${INITIAL_HOST}" ]; then
        echo ">>> [STEP 2] Hostname transition detected: ${INITIAL_HOST} -> ${CUR_HOST} <<<"
        break
    fi

    if [ "${CUR_BOOT}" != "${INITIAL_BOOT}" ]; then
        echo ">>> [STEP 2] Kernel boot_id transition detected: ${INITIAL_BOOT} -> ${CUR_BOOT} <<<"
        break
    fi

    if [ -f /tmp/migration_restored ] || [ -f /dev/shm/migration_restored ] || [ -f "${CHECKPOINT_DIR}/migration_restored" ]; then
        echo ">>> [STEP 2] Migration marker file detected! <<<"
        break
    fi

    # Check if helper failed
    if [ -f "${CHECKPOINT_DIR}/dump_failed" ]; then
        echo ">>> [STEP 2] [ERROR] Checkpoint helper reported dump failure! <<<"
        if [ -f "${CHECKPOINT_DIR}/dump.log" ]; then
            echo "--- dump.log tail ---"
            tail -n 40 "${CHECKPOINT_DIR}/dump.log" 2>/dev/null || true
        fi
        exit 1
    fi

    sleep 0.1
done

echo "=========================================================="
echo "=== STEP 2: Successfully migrated into MicroVM!        ==="
echo "=== Restored Hostname: $(hostname)                     ==="
echo "=== Restored PID 1:    $(cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ' || echo "unknown") ==="
echo "=== Restored Kernel:   $(uname -r)                     ==="
echo "=========================================================="

exit 0
