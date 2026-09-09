#!/usr/bin/env bash
set -euo pipefail

# scripts/setup_step.sh
# Main orchestrator for Step 2 ("Checkpoint & Migrate to VM").

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECKPOINT_DIR="${REPO_DIR}/checkpoint"
MIGRATION_TARGET="${MIGRATION_TARGET:-worker}"

echo "=== [STEP 2] Orchestration Starting (target=${MIGRATION_TARGET}) ==="
echo "Working directory: ${REPO_DIR}"

# 1. Compile daemonize helper if binary does not exist
if [ ! -x "${SCRIPT_DIR}/daemonize" ]; then
    echo "[STEP 2] Compiling C daemonizer helper..."
    gcc -O2 -Wall "${SCRIPT_DIR}/daemonize.c" -o "${SCRIPT_DIR}/daemonize"
fi

# 2. Discover Runner.Listener and Runner.Worker PIDs
LISTENER_PID=$(pgrep -f "Runner.Listener" | head -n 1 || echo "")
if [ -z "${LISTENER_PID}" ]; then
    echo "[STEP 2] [ERROR] Could not find Runner.Listener process!"
    ps aux | grep -i runner || true
    exit 1
fi

WORKER_PID=$(pgrep -f "Runner.Worker" | head -n 1 || echo "")
echo "[STEP 2] Identified Runner.Listener PID: ${LISTENER_PID}"
echo "[STEP 2] Identified Runner.Worker   PID: ${WORKER_PID}"

# 3. Pre-process and sanitize listener file descriptors (closing /dev/pts leakage)
echo "[STEP 2] Sanitizing Runner.Listener file descriptors..."
chmod +x "${SCRIPT_DIR}/fix_listener_fds.sh"
sudo "${SCRIPT_DIR}/fix_listener_fds.sh" "${LISTENER_PID}"

# 4. Prepare checkpoint directory
rm -rf "${CHECKPOINT_DIR}"
mkdir -p "${CHECKPOINT_DIR}"
chmod +x "${SCRIPT_DIR}/checkpoint_helper.sh" "${SCRIPT_DIR}/detect_migration.sh"
chmod +x "${SCRIPT_DIR}/is_vm_wait.sh" "${SCRIPT_DIR}/smoke_is_vm_helper.sh"

export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-the-actual-real-morsho/runner-criu-test}"
export GITHUB_RUN_ID="${GITHUB_RUN_ID:-0}"
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"
export GH_TOKEN="${GITHUB_TOKEN:-}"

if [ "${MIGRATION_TARGET}" = "worker" ]; then
    if [ -z "${WORKER_PID}" ]; then
        echo "[STEP 2] [ERROR] Worker migration requires Runner.Worker PID"
        exit 1
    fi

    echo "[STEP 2] Launching Worker leave-running migration helper..."
    export ALLOW_WORKER_DUMP=1
    export RUNNER_VM_CHECKPOINT="${CHECKPOINT_DIR}"
    export IS_VM_MAX_WAIT_SEC="${IS_VM_MAX_WAIT_SEC:-600}"
    sudo -E "${SCRIPT_DIR}/daemonize" \
        "${SCRIPT_DIR}/smoke_is_vm_helper.sh" \
        "${WORKER_PID}" \
        "${CHECKPOINT_DIR}" \
        "${REPO_DIR}" \
        "${REPO_DIR}/vm_serial.log" \
        "worker"

    echo "[STEP 2] Waiting for restored step to write vm_done..."
    "${SCRIPT_DIR}/is_vm_wait.sh"

    for i in $(seq 1 90); do
        if [ -f "${CHECKPOINT_DIR}/helper_done" ] || [ -f "${CHECKPOINT_DIR}/helper_failed" ]; then
            echo "[STEP 2] helper finished at ${i}s"
            break
        fi
        sleep 1
    done
    sudo chmod -R a+rX "${CHECKPOINT_DIR}" "${REPO_DIR}/vm_serial.log" 2>/dev/null || true

    if [ ! -f "${CHECKPOINT_DIR}/vm_done" ]; then
        echo "[STEP 2] [ERROR] Worker migration finished without vm_done"
        exit 1
    fi
    if [ "$(cat "${CHECKPOINT_DIR}/restore.rc" 2>/dev/null)" != "0" ]; then
        echo "[STEP 2] [ERROR] VM criu restore failed (restore.rc != 0)"
        exit 1
    fi
    grep -qE 'tag=vm_(entry|loop)' "${CHECKPOINT_DIR}/vm_done" \
        || echo "[STEP 2] WARN: vm_done used restore_fallback — see post_restore_diag.txt"
else
    echo "[STEP 2] Launching detached Listener checkpoint helper via daemonize..."
    export ALLOW_LISTENER_DUMP=1
    export T9_CANCEL_ON_QEMU_EXIT=1
    sudo -E "${SCRIPT_DIR}/daemonize" \
        "${SCRIPT_DIR}/checkpoint_helper.sh" \
        "${LISTENER_PID}" \
        "${WORKER_PID}" \
        "${CHECKPOINT_DIR}"

    echo "[STEP 2] Entering migration detection loop..."
    "${SCRIPT_DIR}/detect_migration.sh" "${CHECKPOINT_DIR}"
fi

echo "=== [STEP 2] Orchestration Finished Successfully in VM! ==="
exit 0
