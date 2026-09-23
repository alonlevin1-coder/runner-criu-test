#!/usr/bin/env bash
# Snapshot GitHub Actions runner _diag logs (Worker, pages, blocks) into checkpoint.
set -euo pipefail

CP="${RUNNER_VM_CHECKPOINT:-checkpoint}"
CP="$(mkdir -p "${CP}" && cd "${CP}" && pwd)"
TAG="${1:-snapshot}"
DEST="${CP}/vm_diag/${TAG}"

log() { echo "[collect_runner_diag] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

probe_diag_paths() {
    local out="${CP}/diag_probe.txt"
    {
        echo "=== diag probe $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
        echo "GITHUB_WORKSPACE=${GITHUB_WORKSPACE:-}"
        echo "RUNNER_TEMP=${RUNNER_TEMP:-}"
        echo "RUNNER_TOOL_CACHE=${RUNNER_TOOL_CACHE:-}"
        echo "is_vm=$(test -f /tmp/is_vm && echo yes || echo no)"
        echo "--- ls /home/runner/work ---"
        ls -la /home/runner/work 2>&1 || true
        echo "--- ls /home/runner/work/_diag ---"
        ls -la /home/runner/work/_diag 2>&1 | head -20 || true
        echo "--- find _diag under /home/runner (maxdepth 5) ---"
        find /home/runner -maxdepth 5 -type d -name '_diag' 2>/dev/null | head -10 || true
        echo "--- Worker pid / cwd ---"
        local wp
        wp="$(pgrep -f 'Runner\.Worker' | head -n1 || true)"
        echo "worker_pid=${wp}"
        if [ -n "${wp}" ] && [ -d "/proc/${wp}" ]; then
            echo "worker_cwd=$(readlink -f "/proc/${wp}/cwd" 2>/dev/null || true)"
            tr '\0' '\n' < "/proc/${wp}/environ" 2>/dev/null | grep -E '^(GITHUB_|RUNNER_|ACTIONS_)' || true
            echo "worker_fd_diag:"
            ls -la "/proc/${wp}/fd" 2>/dev/null | head -20 || true
        fi
        echo
    } >> "${out}"
}

find_diag_root() {
    local d found wp
    probe_diag_paths
    for d in \
        "${RUNNER_DIAGNOSTIC_LOG:-}" \
        "${GITHUB_WORKSPACE:-}/../_diag" \
        "${GITHUB_WORKSPACE:-}/../../_diag" \
        "/home/runner/work/_diag" \
        "${RUNNER_TEMP:-}/../_diag" \
        "${RUNNER_TEMP:-}/_diag"; do
        [ -n "${d}" ] || continue
        d="$(readlink -f "${d}" 2>/dev/null || true)"
        [ -n "${d}" ] && [ -d "${d}" ] || continue
        echo "${d}"
        return 0
    done
    found="$(find /home/runner -maxdepth 6 -type d -name '_diag' 2>/dev/null | head -n 1 || true)"
    [ -n "${found}" ] && echo "${found}" && return 0
    wp="$(pgrep -f 'Runner\.Worker' | head -n1 || true)"
    if [ -n "${wp}" ]; then
        found="$(readlink -f "/proc/${wp}/cwd/_diag" 2>/dev/null || true)"
        [ -n "${found}" ] && [ -d "${found}" ] && echo "${found}" && return 0
        found="$(readlink -f "/proc/${wp}/cwd/../_diag" 2>/dev/null || true)"
        [ -n "${found}" ] && [ -d "${found}" ] && echo "${found}" && return 0
    fi
    return 1
}

summarize_diag() {
    local diag_root="${1:?}"
    local tag="${2:-snapshot}"
    local out="${CP}/r26_diag_timeline.txt"
    {
        echo "=== ${tag} $(date -u +%Y-%m-%dT%H:%M:%SZ) diag_root=${diag_root} ==="
        grep -hE 'JobServerQueue|ResultServer|WebConsole|websocket|WebSocket|web console|AppendTimeline|OutputManager|ProcessWebConsole|Stop aggressive|Try to append|Try to upload|Successfully started|Failed|ERROR|WARN' \
            "${diag_root}"/Worker*.log \
            "${diag_root}"/pages/*.log \
            "${diag_root}"/blocks/*.log 2>/dev/null \
            | tail -n 120 || echo "(no matching diag lines yet)"
        echo
    } >> "${out}"
}

DIAG_ROOT="$(find_diag_root || true)"
if [ -z "${DIAG_ROOT}" ]; then
    log "WARN: _diag root not found"
    echo "diag_root=missing tag=${TAG}" >> "${CP}/r26_diag_timeline.txt"
    exit 0
fi

log "tag=${TAG} diag_root=${DIAG_ROOT} -> ${DEST}"
rm -rf "${DEST}"
mkdir -p "${DEST}"
cp -a "${DIAG_ROOT}/." "${DEST}/" 2>/dev/null || true
chmod -R a+rX "${DEST}" 2>/dev/null || true
summarize_diag "${DIAG_ROOT}" "${TAG}"
sync
