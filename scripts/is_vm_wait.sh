#!/usr/bin/env bash
# Host/VM migrate wait: block until migrator_ok, then VM finishes step 2 or host sleeps forever.
set -euo pipefail

CP="${RUNNER_VM_CHECKPOINT:-checkpoint}"
CP="$(cd "${CP}" 2>/dev/null && pwd || echo "${CP}")"
MIGRATOR_OK="${CP}/migrator_ok"
MARKER="${CP}/guest_progress.txt"

log() { echo "[is_vm_wait] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

write_vm_done() {
    local tag="${1:-vm}"
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "vm_done ts=${TS} tag=${tag}" > "${CP}/vm_done"
    echo "${tag} ok ${TS}" >> "${MARKER}" 2>/dev/null || true
    log "wrote ${CP}/vm_done tag=${tag}"
}

run_post_migration() {
    local script="${POST_MIGRATION_SCRIPT:-}"
    [ -n "${script}" ] || return 0
    [ -f "${script}" ] || { log "POST_MIGRATION_SCRIPT missing: ${script}"; return 1; }
    log "running post-migration script ${script}"
    bash "${script}"
}

legacy_wait() {
    if [ -f /tmp/is_vm ]; then
        log "VM branch (/tmp/is_vm present at entry)"
        run_post_migration
        write_vm_done "vm_entry"
        exit 0
    fi

    log "Host branch waiting (legacy, pid=$$ cp=${CP})"
    touch "${CP}/wait_loop_ready"
    log "signaled wait_loop_ready"
    MAX_WAIT="${IS_VM_MAX_WAIT_SEC:-600}"
    START=$(date +%s)
    while [ ! -f "${CP}/vm_done" ]; do
        NOW=$(date +%s)
        if [ $((NOW - START)) -ge "${MAX_WAIT}" ]; then
            log "timeout after ${MAX_WAIT}s waiting for vm_done"
            exit 124
        fi
        if [ -f /tmp/is_vm ]; then
            log "VM branch detected inside wait loop"
            run_post_migration
            write_vm_done "vm_loop"
            exit 0
        fi
        sleep 2
    done
    log "host saw vm_done"
    exit 0
}

if [ "${IS_VM_WAIT_LEGACY:-0}" = "1" ]; then
    legacy_wait
fi

if [ -f /tmp/is_vm ] && [ -f "${MIGRATOR_OK}" ]; then
    log "VM re-entry with migrator_ok — completing migrate step"
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "vm_migrate_step_done ts=${TS}" > "${CP}/vm_migrate_step_done"
    write_vm_done "vm_branch"
    exit 0
fi

log "waiting for migrator_ok (pid=$$ cp=${CP})"
touch "${CP}/wait_loop_ready"
log "signaled wait_loop_ready"

MAX_WAIT="${IS_VM_MAX_WAIT_SEC:-600}"
START=$(date +%s)
while [ ! -f "${MIGRATOR_OK}" ]; do
    NOW=$(date +%s)
    if [ $((NOW - START)) -ge "${MAX_WAIT}" ]; then
        log "timeout after ${MAX_WAIT}s waiting for migrator_ok"
        exit 124
    fi
    sleep 2
done
log "migrator_ok: $(head -n1 "${MIGRATOR_OK}" 2>/dev/null || echo present)"

if [ -f /tmp/is_vm ]; then
    log "VM branch — completing migrate step (StepsRunner continues)"
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "vm_migrate_step_done ts=${TS}" > "${CP}/vm_migrate_step_done"
    write_vm_done "vm_branch"
    exit 0
fi

log "host branch — blocking forever (host Worker stays on step 2)"
echo "host_blocked ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${CP}/state.txt" 2>/dev/null || true
exec sleep "${HOST_BLOCK_SLEEP_SEC:-10000000}"
