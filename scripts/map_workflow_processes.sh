#!/usr/bin/env bash
# Map GHA runner process tree: what to freeze/checkpoint vs keep running.
set -euo pipefail

CHECKPOINT_DIR="${1:-checkpoint}"
STEP_PID="${2:-$$}"

CHECKPOINT_DIR="$(mkdir -p "${CHECKPOINT_DIR}" && cd "${CHECKPOINT_DIR}" && pwd)"
OUT="${CHECKPOINT_DIR}/process_map.txt"
TSV="${CHECKPOINT_DIR}/process_map.tsv"
PLAN="${CHECKPOINT_DIR}/freeze_plan.txt"

log() { echo "$*" | tee -a "${OUT}"; }

cmdline_of() {
    tr '\0' ' ' < "/proc/${1}/cmdline" 2>/dev/null || true
}

ppid_of() {
    awk '/^PPid:/ {print $2; exit}' "/proc/${1}/status" 2>/dev/null || true
}

comm_of() {
    awk '/^Name:/ {print $2; exit}' "/proc/${1}/status" 2>/dev/null || true
}

is_descendant_of() {
    local root="${1:?}" pid="${2:?}"
    local p="${pid}" guard=0
    while [ -n "${p}" ] && [ "${p}" != "0" ] && [ "${guard}" -lt 64 ]; do
        [ "${p}" = "${root}" ] && return 0
        p="$(ppid_of "${p}")"
        guard=$((guard + 1))
    done
    return 1
}

collect_descendants() {
    local root="${1:?}"
    local -a queue=("${root}")
    local pid child

    printf '%s\n' "${root}"
    while [ "${#queue[@]}" -gt 0 ]; do
        pid="${queue[0]}"
        queue=("${queue[@]:1}")
        while read -r child; do
            [ -n "${child}" ] || continue
            queue+=("${child}")
            printf '%s\n' "${child}"
        done < <(pgrep -P "${pid}" 2>/dev/null || true)
    done
}

classify_role() {
    local pid="${1:?}" cmd="${2:-}"
    case "${cmd}" in
        *Runner.Listener*) echo "listener" ;;
        *Runner.Worker*|*Runner.Worker.dll*) echo "worker" ;;
        *Runner.Worker*) echo "worker" ;;
        *bash*|*dash*|*sh\ *) echo "shell" ;;
        *dotnet*) echo "dotnet" ;;
        *qemu-system*) echo "qemu" ;;
        *criu*) echo "criu" ;;
        *daemonize*) echo "daemonize" ;;
        *smoke_is_vm*|*is_vm_wait*|*map_workflow*) echo "migration_orchestrator" ;;
        *) echo "other" ;;
    esac
}

recommend_action() {
    local pid="${1:?}" role="${2:?}" rel_step="${3:?}" rel_worker="${4:?}" in_worker="${5:?}"

    if [ "${pid}" = "${STEP_PID}" ] || [ "${rel_step}" = "step_descendant" ]; then
        echo "LEAVE_RUNNING|orchestrator step shell subtree — must not SIGSTOP"
        return 0
    fi
    if [ "${role}" = "listener" ]; then
        echo "LEAVE_RUNNING|Listener keeps hosted VM alive (R13/R14)"
        return 0
    fi
    if [ "${role}" = "migration_orchestrator" ] || [ "${role}" = "daemonize" ]; then
        echo "LEAVE_RUNNING|detached migration helper (if reparented to init)"
        return 0
    fi
    if [ "${in_worker}" = "yes" ] && { [ "${role}" = "worker" ] || [ "${role}" = "dotnet" ] || [ "${role}" = "other" ]; }; then
        echo "FREEZE_AND_CHECKPOINT|job state lives in Worker subtree"
        return 0
    fi
    if [ "${rel_worker}" = "worker_ancestor" ]; then
        echo "LEAVE_RUNNING|ancestor of Worker — outside dump root"
        return 0
    fi
    echo "REVIEW|unexpected relation — inspect manually"
}

count_estab_sockets() {
    local pid="${1:?}"
    ss -H -tanp 2>/dev/null | grep -cF "pid=${pid}," || echo 0
}

: > "${OUT}"
: > "${TSV}"
printf 'pid\tppid\tcomm\trole\trel_step\trel_worker\tin_worker_subtree\testab_sockets\taction\treason\tcmdline\n' > "${TSV}"

LISTENER_PID="$(pgrep -f 'Runner\.Listener' | head -n1 || true)"
WORKER_PID="$(pgrep -f 'Runner\.Worker' | head -n1 || true)"
DAEMON_HELPER_PID="$(pgrep -f 'smoke_is_vm_helper\.sh' | head -n1 || true)"

log "=== Workflow process map $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
log "STEP_PID=${STEP_PID} (this step shell)"
log "LISTENER_PID=${LISTENER_PID:-none}"
log "WORKER_PID=${WORKER_PID:-none}"
log "DAEMON_HELPER_PID=${DAEMON_HELPER_PID:-none}"
log "GITHUB_RUN_ID=${GITHUB_RUN_ID:-0}"
log ""

declare -A IN_WORKER=()
if [ -n "${WORKER_PID}" ]; then
    while read -r pid; do
        [ -n "${pid}" ] || continue
        IN_WORKER["${pid}"]=1
    done < <(collect_descendants "${WORKER_PID}")
fi

declare -A IN_STEP=()
while read -r pid; do
    [ -n "${pid}" ] || continue
    IN_STEP["${pid}"]=1
done < <(collect_descendants "${STEP_PID}")

log "=== Step shell ancestry (STEP_PID -> root) ==="
p="${STEP_PID}"
guard=0
while [ -n "${p}" ] && [ "${p}" != "0" ] && [ "${guard}" -lt 32 ]; do
    log "  pid=${p} ppid=$(ppid_of "${p}") comm=$(comm_of "${p}") cmd=$(cmdline_of "${p}" | cut -c1-120)"
    [ "${p}" = "${WORKER_PID:-}" ] && log "    ^^^ Runner.Worker"
    [ "${p}" = "${LISTENER_PID:-}" ] && log "    ^^^ Runner.Listener"
    p="$(ppid_of "${p}")"
    guard=$((guard + 1))
done
log ""

log "=== pstree (Listener / Worker / step) ==="
if command -v pstree >/dev/null 2>&1; then
    [ -n "${LISTENER_PID}" ] && pstree -p "${LISTENER_PID}" 2>/dev/null | tee -a "${OUT}" || true
    [ -n "${WORKER_PID}" ] && pstree -p "${WORKER_PID}" 2>/dev/null | tee -a "${OUT}" || true
    pstree -p "${STEP_PID}" 2>/dev/null | tee -a "${OUT}" || true
else
    log "(pstree not installed)"
fi
log ""

log "=== Worker direct children ==="
if [ -n "${WORKER_PID}" ]; then
    while read -r cpid; do
        [ -n "${cpid}" ] || continue
        mark=""
        [ "${cpid}" = "${STEP_PID}" ] && mark=" <-- STEP_SHELL"
        is_descendant_of "${STEP_PID}" "${cpid}" && [ "${cpid}" != "${STEP_PID}" ] && mark=" <-- step_descendant"
        log "  child pid=${cpid} comm=$(comm_of "${cpid}") cmd=$(cmdline_of "${cpid}" | cut -c1-100)${mark}"
    done < <(pgrep -P "${WORKER_PID}" 2>/dev/null || true)
fi
log ""

log "=== Full classification (Worker subtree + step subtree + daemons) ==="
declare -A SEEN=()
CANDIDATE_PIDS=()
[ -n "${LISTENER_PID}" ] && CANDIDATE_PIDS+=("${LISTENER_PID}")
[ -n "${WORKER_PID}" ] && CANDIDATE_PIDS+=("${WORKER_PID}")
[ -n "${DAEMON_HELPER_PID}" ] && CANDIDATE_PIDS+=("${DAEMON_HELPER_PID}")
while read -r pid; do CANDIDATE_PIDS+=("${pid}"); done < <(collect_descendants "${WORKER_PID:-0}" 2>/dev/null || true)
while read -r pid; do CANDIDATE_PIDS+=("${pid}"); done < <(collect_descendants "${STEP_PID}")

for pid in "${CANDIDATE_PIDS[@]}"; do
    [ -n "${pid}" ] || continue
    [ -d "/proc/${pid}" ] || continue
    [ -n "${SEEN[${pid}]+x}" ] && continue
    SEEN["${pid}"]=1

    cmd="$(cmdline_of "${pid}")"
    comm="$(comm_of "${pid}")"
    ppid="$(ppid_of "${pid}")"
    role="$(classify_role "${pid}" "${cmd}")"

    rel_step="unrelated"
    if [ "${pid}" = "${STEP_PID}" ]; then
        rel_step="step_self"
    elif is_descendant_of "${STEP_PID}" "${pid}"; then
        rel_step="step_descendant"
    elif is_descendant_of "${pid}" "${STEP_PID}"; then
        rel_step="step_ancestor"
    fi

    rel_worker="unrelated"
    in_worker="no"
    if [ -n "${WORKER_PID}" ]; then
        if [ "${pid}" = "${WORKER_PID}" ]; then
            rel_worker="worker_self"
            in_worker="yes"
        elif is_descendant_of "${WORKER_PID}" "${pid}"; then
            rel_worker="worker_descendant"
            in_worker="yes"
        elif is_descendant_of "${pid}" "${WORKER_PID}"; then
            rel_worker="worker_ancestor"
        fi
    fi

    estab="$(count_estab_sockets "${pid}")"
    IFS='|' read -r action reason <<< "$(recommend_action "${pid}" "${role}" "${rel_step}" "${rel_worker}" "${in_worker}")"

    log "pid=${pid} ppid=${ppid} comm=${comm} role=${role}"
    log "  rel_step=${rel_step} rel_worker=${rel_worker} in_worker=${in_worker} estab=${estab}"
    log "  action=${action} reason=${reason}"
    log "  cmd=${cmd:0:160}"
    log ""

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${pid}" "${ppid}" "${comm}" "${role}" "${rel_step}" "${rel_worker}" \
        "${in_worker}" "${estab}" "${action}" "${reason}" "${cmd:0:200}" >> "${TSV}"
done

log "=== Dump root candidates (Worker children excluding step shell branch) ==="
BEST_DUMP=""
if [ -n "${WORKER_PID}" ]; then
    while read -r cpid; do
        [ -n "${cpid}" ] || continue
        [ "${cpid}" = "${STEP_PID}" ] && continue
        is_descendant_of "${STEP_PID}" "${cpid}" && continue
        cmd="$(cmdline_of "${cpid}")"
        role="$(classify_role "${cpid}" "${cmd}")"
        estab="$(count_estab_sockets "${cpid}")"
        log "  candidate pid=${cpid} role=${role} estab=${estab} cmd=${cmd:0:120}"
        if [ -z "${BEST_DUMP}" ] && { [ "${role}" = "dotnet" ] || [ "${role}" = "worker" ]; }; then
            BEST_DUMP="${cpid}"
        fi
    done < <(pgrep -P "${WORKER_PID}" 2>/dev/null || true)
fi
if [ -z "${BEST_DUMP}" ] && [ -n "${WORKER_PID}" ]; then
    BEST_DUMP="${WORKER_PID}"
    log "  (no sibling job child — fallback dump root = WORKER_PID)"
else
    log "  suggested DUMP_ROOT_PID=${BEST_DUMP}"
fi
log ""

{
    echo "=== Freeze / checkpoint plan ==="
    echo "STEP_PID=${STEP_PID}"
    echo "WORKER_PID=${WORKER_PID:-none}"
    echo "LISTENER_PID=${LISTENER_PID:-none}"
    echo "SUGGESTED_DUMP_ROOT_PID=${BEST_DUMP:-none}"
    echo ""
    echo "Exclude from freeze (orchestrator):"
    awk -F'\t' '$9=="LEAVE_RUNNING" && ($5 ~ /^step_/ || $4 ~ /shell|migration/) {print "  pid="$1" role="$4" cmd="$11}' "${TSV}" || true
    echo ""
    echo "Must freeze + checkpoint (job subtree):"
    awk -F'\t' '$9=="FREEZE_AND_CHECKPOINT" {print "  pid="$1" role="$4" estab="$8" cmd="$11}' "${TSV}" || true
    echo ""
    echo "If step shell is Worker descendant (typical):"
    echo "  - Add STEP_PID to freeze_exclude_pids.txt"
    echo "  - Or use DUMP_ROOT_PID=${BEST_DUMP:-WORKER_PID} if job is a sibling process"
    echo "  - Brief SIGSTOP step shell only during criu dump if it remains in dump tree"
} | tee "${PLAN}" >> "${OUT}"

chmod a+rw "${OUT}" "${TSV}" "${PLAN}" 2>/dev/null || true
echo "process_map written to ${OUT}"
