#!/usr/bin/env bash
# Shared host/VM wait loop: host polls vm_done; VM branch detects /tmp/is_vm and writes it.
set -euo pipefail

CP="${RUNNER_VM_CHECKPOINT:-checkpoint}"
CP="$(cd "${CP}" 2>/dev/null && pwd || echo "${CP}")"
MARKER="${CP}/guest_progress.txt"

log() { echo "[is_vm_wait] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

write_vm_done() {
    local tag="${1:-vm}"
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "vm_done ts=${TS} tag=${tag}" > "${CP}/vm_done"
    echo "${tag} ok ${TS}" >> "${MARKER}" 2>/dev/null || true
    log "wrote ${CP}/vm_done tag=${tag}"
}

if [ -f /tmp/is_vm ]; then
    log "VM branch (/tmp/is_vm present at entry)"
    write_vm_done "vm_entry"
    exit 0
fi

log "Host branch waiting (pid=$$ cp=${CP})"
touch "${CP}/wait_loop_ready"
log "signaled wait_loop_ready"
MAX_WAIT="${IS_VM_MAX_WAIT_SEC:-600}"
ELAPSED=0
while [ ! -f "${CP}/vm_done" ]; do
    if [ "${ELAPSED}" -ge "${MAX_WAIT}" ]; then
        log "timeout after ${MAX_WAIT}s waiting for vm_done"
        exit 124
    fi
    if [ -f /tmp/is_vm ]; then
        log "VM branch detected inside wait loop"
        write_vm_done "vm_loop"
        exit 0
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done
log "host saw vm_done"
exit 0
