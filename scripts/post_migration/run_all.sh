#!/usr/bin/env bash
# Runs all post-migration workloads inside the VM during the migrate window.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CP="${RUNNER_VM_CHECKPOINT:-checkpoint}"
CP="$(cd "${CP}" 2>/dev/null && pwd || echo "${CP}")"
mkdir -p "${CP}"

log() { echo "[post_migration] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

step_paths() {
    local key="$1"
    if [[ "${key}" =~ ^[0-9]+$ ]]; then
        echo "${CP}/vm_step${key}_output.txt"
        echo "${CP}/vm_step${key}_done"
    else
        echo "${CP}/vm_step_${key}_output.txt"
        echo "${CP}/vm_step_${key}_done"
    fi
}

run_step() {
    local key="$1" script="$2"
    local out done
    mapfile -t paths < <(step_paths "${key}")
    out="${paths[0]}"
    done="${paths[1]}"

    log "start step=${key} script=${script}"
    rm -f "${out}" "${done}"
    if bash "${script}" > "${out}" 2>&1; then
        touch "${done}"
        log "ok step=${key}"
    else
        rc=$?
        echo "STEP ${key} FAILED rc=${rc}" >> "${out}"
        log "fail step=${key} rc=${rc}"
        return "${rc}"
    fi
    sync
}

STEPS=(
    "3:${SCRIPT_DIR}/hello.sh"
    "network:${SCRIPT_DIR}/network.sh"
    "filesystem:${SCRIPT_DIR}/filesystem.sh"
    "download:${SCRIPT_DIR}/download_verify.sh"
    "git:${SCRIPT_DIR}/git_workspace.sh"
)

: > "${CP}/vm_post_migration_manifest.txt"
for spec in "${STEPS[@]}"; do
    key="${spec%%:*}"
    script="${spec#*:}"
    run_step "${key}" "${script}"
    echo "${key}" >> "${CP}/vm_post_migration_manifest.txt"
done

touch "${CP}/vm_post_migration_complete"
sync
log "all post-migration steps complete"
