#!/usr/bin/env bash
# Push checkpoint text logs to a debug branch (no binary .img files).
set -euo pipefail

CHECKPOINT_DIR="${1:-checkpoint}"
REPO_DIR="${2:-.}"
LABEL="${3:-R30}"

CHECKPOINT_DIR="$(cd "${CHECKPOINT_DIR}" 2>/dev/null && pwd || echo "${CHECKPOINT_DIR}")"
REPO_DIR="$(cd "${REPO_DIR}" && pwd)"
RUN_ID="${GITHUB_RUN_ID:-0}"
BRANCH="debug-${LABEL}-${RUN_ID}"

[ "${UPLOAD_DEBUG_BRANCH:-0}" = "1" ] || exit 0
[ -n "${GITHUB_RUN_ID:-}" ] && [ "${GITHUB_RUN_ID}" != "0" ] || exit 0

(
    cd "${REPO_DIR}"
    git config --global --add safe.directory "*" 2>/dev/null || true
    git config user.name "CRIU Debug Bot"
    git config user.email "bot@criu.test"
    git checkout -B "${BRANCH}" 2>/dev/null || exit 0
    rm -rf debug_logs
    mkdir -p debug_logs
    cp -a "${CHECKPOINT_DIR}"/*.log "${CHECKPOINT_DIR}"/*.txt debug_logs/ 2>/dev/null || true
    [ -f smoke-logs/vm_serial.log ] && cp -a smoke-logs/vm_serial.log debug_logs/ 2>/dev/null || true
    [ -f smoke-logs/host-wait.log ] && cp -a smoke-logs/host-wait.log debug_logs/ 2>/dev/null || true
    git add debug_logs/ 2>/dev/null || true
    git commit -m "Debug snapshot ${LABEL} run ${RUN_ID}" 2>/dev/null || exit 0
    timeout 30s git push -f origin "${BRANCH}" 2>/dev/null || true
) || true
