#!/usr/bin/env bash
set -euo pipefail

# scripts/setup_step.sh
# Main orchestrator for Step 2 ("Checkpoint & Migrate to VM").

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECKPOINT_DIR="${REPO_DIR}/checkpoint"

echo "=== [STEP 2] Orchestration Starting ==="
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
chmod +x "${SCRIPT_DIR}/checkpoint_helper.sh"
chmod +x "${SCRIPT_DIR}/detect_migration.sh"

# 5. Launch detached checkpoint helper
echo "[STEP 2] Launching detached checkpoint helper via daemonize..."
sudo "${SCRIPT_DIR}/daemonize" "${SCRIPT_DIR}/checkpoint_helper.sh" "${LISTENER_PID}" "${WORKER_PID}" "${CHECKPOINT_DIR}"

# 6. Enter migration wait loop
echo "[STEP 2] Entering migration detection loop..."
"${SCRIPT_DIR}/detect_migration.sh" "${CHECKPOINT_DIR}"

echo "=== [STEP 2] Orchestration Finished Successfully in VM! ==="
exit 0
