#!/usr/bin/env bash
# Snapshot GitHub Actions runner _diag logs (Worker, pages, blocks) into checkpoint.
set -euo pipefail

CP="${RUNNER_VM_CHECKPOINT:-checkpoint}"
CP="$(mkdir -p "${CP}" && cd "${CP}" && pwd)"
TAG="${1:-snapshot}"
DEST="${CP}/vm_diag/${TAG}"

log() { echo "[collect_runner_diag] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

find_diag_root() {
    local d
    for d in \
        "${GITHUB_WORKSPACE:-}/../_diag" \
        "${GITHUB_WORKSPACE:-}/../../_diag" \
        "/home/runner/work/_diag" \
        "${RUNNER_TEMP:-}/../_diag"; do
        [ -n "${d}" ] || continue
        d="$(cd "${d}" 2>/dev/null && pwd || true)"
        [ -n "${d}" ] && [ -d "${d}" ] || continue
        echo "${d}"
        return 0
    done
    find /home/runner/work -maxdepth 4 -type d -name '_diag' 2>/dev/null | head -n 1
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
