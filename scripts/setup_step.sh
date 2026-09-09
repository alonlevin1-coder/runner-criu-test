#!/usr/bin/env bash
set -euo pipefail

# scripts/setup_step.sh
# Main orchestrator for Step 2 ("Checkpoint & Migrate to VM").

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECKPOINT_DIR="${REPO_DIR}/checkpoint"
MIGRATION_TARGET="${MIGRATION_TARGET:-worker}"

if [ -f /tmp/is_vm ]; then
    echo "=== [STEP 2] Already in VM (/tmp/is_vm present) — skip migration ==="
    exit 0
fi

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

# 3. Listener FD fix (Listener dump path only; Worker leave-running keeps Listener as-is)
if [ "${MIGRATION_TARGET}" != "worker" ]; then
    echo "[STEP 2] Sanitizing Runner.Listener file descriptors..."
    chmod +x "${SCRIPT_DIR}/fix_listener_fds.sh"
    sudo "${SCRIPT_DIR}/fix_listener_fds.sh" "${LISTENER_PID}"
fi

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
    sudo -E "${SCRIPT_DIR}/daemonize" \
        "${SCRIPT_DIR}/smoke_is_vm_helper.sh" \
        "${WORKER_PID}" \
        "${CHECKPOINT_DIR}" \
        "${REPO_DIR}" \
        "${REPO_DIR}/vm_serial.log" \
        "worker"
    echo "[STEP 2] Helper launched — caller must run scripts/is_vm_wait.sh (R16 pattern)"
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
