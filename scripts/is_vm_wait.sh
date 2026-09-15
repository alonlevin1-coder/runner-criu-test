#!/usr/bin/env bash
# Host/VM migrate wait: block until migrator_ok, then VM finishes step 2 or host sleeps forever.
set -euo pipefail

CP="${RUNNER_VM_CHECKPOINT:-checkpoint}"
if [ -f /tmp/is_vm ] && [ -d /mnt/checkpoint ]; then
    CP="/mnt/checkpoint"
fi
CP="$(cd "${CP}" 2>/dev/null && pwd || echo "${CP}")"
MIGRATOR_OK="${CP}/migrator_ok"
MARKER="${CP}/guest_progress.txt"
NTFY_TOPIC="${NTFY_TOPIC:-runner-criu-r30-tap-morsho}"
HOST_WATCH_PID=""

log() { echo "[is_vm_wait] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

wait_stage() {
    local stage="${1:?}"
    local detail="${2:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "${ts} wait_stage=${stage} run=${GITHUB_RUN_ID:-0} pid=$$ ${detail}" >> "${CP}/helper_stage.txt"
    printf '%s wait_%s %s\n' "${ts}" "${stage}" "${detail}" > "${CP}/wait_stage_latest.txt"
    chmod a+rw "${CP}/helper_stage.txt" "${CP}/wait_stage_latest.txt" 2>/dev/null || true
}

send_ntfy() {
    local title="${1:-is_vm_wait}"
    local msg="${2:-}"
    if [ "${#msg}" -gt 1800 ]; then
        msg="$(printf '%s' "${msg}" | tail -c 1800)"
    fi
    printf '%s' "${msg}" | curl -s --max-time 10 -H "Title: ${title}" --data-binary @- \
        "https://ntfy.sh/${NTFY_TOPIC}" 2>/dev/null || true
}

checkpoint_snapshot() {
    local out=""
    local f
    for f in migrator_ok helper_done helper_failed dump.rc restore.rc \
        vm_migrate_step_done r30_echo_started r30_echo_finished vm_done; do
        if [ -f "${CP}/${f}" ]; then
            out="${out}${f}=$(head -n1 "${CP}/${f}" 2>/dev/null | cut -c1-100)"$'\n'
        fi
    done
    printf '%s' "${out}"
}

start_host_progress_watch() {
    (
        set +e
        for i in $(seq 1 120); do
            sleep 30
            body="$(checkpoint_snapshot)"
            progress="$(tail -n 5 "${MARKER}" 2>/dev/null || echo "(no guest_progress)")"
            {
                echo "t=$(date -u +%H:%M:%S) i=${i} run=${GITHUB_RUN_ID:-0}"
                echo "${body}"
                echo "${progress}"
            } >> "${CP}/host_wait_watchdog.txt"
            send_ntfy "is_vm_wait host ${i}" "run=${GITHUB_RUN_ID:-0}
${body}--- progress ---
${progress}"
            [ -f "${CP}/r30_echo_finished.txt" ] && break
            [ -f "${CP}/helper_failed" ] && break
        done
    ) &
    HOST_WATCH_PID=$!
}

stop_host_progress_watch() {
    [ -n "${HOST_WATCH_PID}" ] && kill "${HOST_WATCH_PID}" 2>/dev/null || true
}

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
        send_ntfy "is_vm_wait VM entry" "run=${GITHUB_RUN_ID:-0} tag=vm_entry"
        run_post_migration
        write_vm_done "vm_entry"
        exit 0
    fi

    log "Host branch waiting (legacy, pid=$$ cp=${CP})"
    send_ntfy "is_vm_wait legacy host" "run=${GITHUB_RUN_ID:-0} cp=${CP}"
    touch "${CP}/wait_loop_ready"
    log "signaled wait_loop_ready"
    MAX_WAIT="${IS_VM_MAX_WAIT_SEC:-600}"
    START=$(date +%s)
    while [ ! -f "${CP}/vm_done" ]; do
        NOW=$(date +%s)
        if [ $((NOW - START)) -ge "${MAX_WAIT}" ]; then
            log "timeout after ${MAX_WAIT}s waiting for vm_done"
            send_ntfy "is_vm_wait TIMEOUT" "legacy host vm_done missing after ${MAX_WAIT}s"
            exit 124
        fi
        if [ -f /tmp/is_vm ]; then
            log "VM branch detected inside wait loop"
            send_ntfy "is_vm_wait VM loop" "run=${GITHUB_RUN_ID:-0} tag=vm_loop"
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
    send_ntfy "is_vm_wait VM re-entry" "run=${GITHUB_RUN_ID:-0} $(head -n1 "${MIGRATOR_OK}" 2>/dev/null || true)"
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "vm_migrate_step_done ts=${TS}" > "${CP}/vm_migrate_step_done"
    write_vm_done "vm_branch"
    exit 0
fi

log "waiting for migrator_ok (pid=$$ cp=${CP})"
[ -f "${CP}/freeze_exclude_pids.txt" ] && echo "$$" >> "${CP}/freeze_exclude_pids.txt" 2>/dev/null || true
wait_stage "waiting" "max=${IS_VM_MAX_WAIT_SEC:-600}s"
send_ntfy "is_vm_wait waiting" "run=${GITHUB_RUN_ID:-0} cp=${CP} max=${IS_VM_MAX_WAIT_SEC:-600}s"
touch "${CP}/wait_loop_ready"
log "signaled wait_loop_ready"

unfreeze_host_tree() {
    local pidfile="${CP}/sigstopped_pids.txt"
    if [ -f "${pidfile}" ]; then
        log "UNFREEZING host worker tree to prevent runner deadlock..."
        while read -r p; do
            [ -n "${p}" ] || continue
            kill -CONT "${p}" 2>/dev/null || sudo kill -CONT "${p}" 2>/dev/null || true
        done < "${pidfile}"
        echo "host_tree_unfrozen=yes" >> "${CP}/state.txt" 2>/dev/null || true
    fi
}

on_wait_exit() {
    local rc=$?
    if [ ! -f "${MIGRATOR_OK}" ] && [ ! -f "${CP}/vm_done" ]; then
        log "is_vm_wait exiting (rc=${rc}) without migrator_ok/vm_done — ensuring host tree unfrozen"
        unfreeze_host_tree
    fi
}
trap on_wait_exit EXIT

check_migration_failed() {
    if [ -f "${CP}/helper_failed" ]; then
        log "helper_failed — migration aborted"
        unfreeze_host_tree
        [ -f "${CP}/dump.rc" ] && log "dump.rc=$(cat "${CP}/dump.rc")"
        [ -f "${CP}/restore.rc" ] && log "restore.rc=$(cat "${CP}/restore.rc")"
        if [ -f "${CP}/post_restore_diag.txt" ]; then
            log "=== post_restore_diag.txt ==="
            cat "${CP}/post_restore_diag.txt" || true
        fi
        if [ -f "${CP}/is_vm_helper.log" ]; then
            log "=== is_vm_helper.log ==="
            cat "${CP}/is_vm_helper.log" || true
        fi
        wait_stage "fail" "helper_failed"
        send_ntfy "is_vm_wait FAIL" "helper_failed run=${GITHUB_RUN_ID:-0}
$(checkpoint_snapshot)
$(tail -n 8 "${MARKER}" 2>/dev/null || true)"
        exit 1
    fi
    if [ -f "${CP}/dump.rc" ] && [ "$(cat "${CP}/dump.rc")" != "0" ]; then
        log "dump failed rc=$(cat "${CP}/dump.rc")"
        unfreeze_host_tree
        send_ntfy "is_vm_wait FAIL" "dump.rc=$(cat "${CP}/dump.rc") run=${GITHUB_RUN_ID:-0}"
        exit 1
    fi
}

MAX_WAIT="${IS_VM_MAX_WAIT_SEC:-600}"
START=$(date +%s)
TICK=0
while [ ! -f "${MIGRATOR_OK}" ]; do
    check_migration_failed
    NOW=$(date +%s)
    if [ $((NOW - START)) -ge "${MAX_WAIT}" ]; then
        log "timeout after ${MAX_WAIT}s waiting for migrator_ok"
        unfreeze_host_tree
        wait_stage "timeout" "no migrator_ok after ${MAX_WAIT}s"
        send_ntfy "is_vm_wait TIMEOUT" "no migrator_ok after ${MAX_WAIT}s run=${GITHUB_RUN_ID:-0}
$(checkpoint_snapshot)
$(tail -n 8 "${MARKER}" 2>/dev/null || true)"
        check_migration_failed
        exit 124
    fi
    TICK=$((TICK + 1))
    if [ $((TICK % 15)) -eq 0 ]; then
        send_ntfy "is_vm_wait poll" "waiting migrator_ok ${TICK}*2s run=${GITHUB_RUN_ID:-0}
$(checkpoint_snapshot)
$(tail -n 5 "${MARKER}" 2>/dev/null || true)"
    fi
    if [ -f /tmp/is_vm ]; then
        log "VM branch detected while waiting for migrator_ok"
        send_ntfy "is_vm_wait VM early" "run=${GITHUB_RUN_ID:-0} migrator_ok not yet present"
        if [ -d /mnt/checkpoint ] && [ ! -f "${MIGRATOR_OK}" ]; then
            CP="/mnt/checkpoint"
            MIGRATOR_OK="${CP}/migrator_ok"
        fi
    fi
    sleep 2
done
log "migrator_ok: $(head -n1 "${MIGRATOR_OK}" 2>/dev/null || echo present)"
wait_stage "migrator_ok" "$(head -n1 "${MIGRATOR_OK}" 2>/dev/null || echo present)"
send_ntfy "is_vm_wait migrator_ok" "$(head -n1 "${MIGRATOR_OK}" 2>/dev/null || echo present) run=${GITHUB_RUN_ID:-0}"

if [ -f /tmp/is_vm ]; then
    if [ -d /mnt/checkpoint ]; then
        CP="/mnt/checkpoint"
    fi
    # Setup Docker socket proxy in guest if socat is available
    if [ ! -S /var/run/docker.sock ] && command -v socat >/dev/null 2>&1; then
        HOST_GW="$(ip route show default 2>/dev/null | awk '{print $3}' | head -n1)"
        HOST_GW="${HOST_GW:-192.168.100.1}"
        sudo mkdir -p /var/run /run
        sudo pkill -f 'UNIX-LISTEN:/var/run/docker.sock' 2>/dev/null || true
        sudo nohup socat UNIX-LISTEN:/var/run/docker.sock,fork,mode=666 "TCP:${HOST_GW}:2375" >/dev/null 2>&1 &
        sudo ln -sf /var/run/docker.sock /run/docker.sock 2>/dev/null || true
        sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
        echo "DOCKER_HOST=unix:///var/run/docker.sock" | sudo tee -a /etc/environment >/dev/null || true
        log "Guest Docker socket bridged to ${HOST_GW}:2375"
    fi

    # Ensure host.docker.internal resolves to 127.0.0.1 in guest
    if ! grep -q "host.docker.internal" /etc/hosts 2>/dev/null; then
        echo "127.0.0.1 host.docker.internal" | sudo tee -a /etc/hosts >/dev/null || true
    fi

    # Setup background port proxy daemon:
    # Bridges host ports published by Docker containers or CI service containers (MariaDB, Redis, etc.)
    # so that localhost:<port> or 127.0.0.1:<port> connects directly to the service.
    if command -v socat >/dev/null 2>&1; then
        HOST_GW="$(ip route show default 2>/dev/null | awk '{print $3}' | head -n1)"
        HOST_GW="${HOST_GW:-192.168.100.1}"
        sudo bash -c "
            proxy_ports() {
                for p in \$*; do
                    [[ \"\${p}\" =~ ^[0-9]+$ ]] || continue
                    [ \"\${p}\" -eq 22 ] && continue
                    [ \"\${p}\" -eq 2375 ] && continue
                    if ! pgrep -f \"TCP-LISTEN:\${p},bind=127.0.0.1\" >/dev/null 2>&1; then
                        nohup socat \"TCP-LISTEN:\${p},bind=127.0.0.1,reuseaddr,fork\" \"TCP:${HOST_GW}:\${p}\" >/dev/null 2>&1 &
                    fi
                done
            }
            # Initial pass: check host listening ports if recorded
            if [ -f /mnt/checkpoint/host_ports.txt ]; then
                proxy_ports \$(cat /mnt/checkpoint/host_ports.txt)
            fi
            # Common CI service ports: 3306 (MySQL/MariaDB), 3308, 5432, 6379
            proxy_ports 3306 3308 5432 6379
            # Continuous monitor: watch docker containers and proxy their published ports
            (
                while true; do
                    if [ -S /var/run/docker.sock ]; then
                        d_ports=''
                        if command -v docker >/dev/null 2>&1; then
                            d_ports=\$(docker ps --format '{{.Ports}}' 2>/dev/null | grep -oE ':[0-9]+->' | tr -d ':->' | sort -u || true)
                        elif command -v curl >/dev/null 2>&1; then
                            d_ports=\$(curl -s --unix-socket /var/run/docker.sock http://localhost/containers/json 2>/dev/null | grep -oE '\"PublicPort\":[0-9]+' | cut -d: -f2 | sort -u || true)
                        fi
                        [ -n \"\${d_ports:-}\" ] && proxy_ports \${d_ports}
                    fi
                    sleep 1
                done
            ) >/dev/null 2>&1 &
        "
        log "Docker localhost port proxy daemon initialized."
    fi
    log "VM branch — completing migrate step (StepsRunner continues)"
    send_ntfy "is_vm_wait VM branch" "run=${GITHUB_RUN_ID:-0} completing migrate step"
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "vm_migrate_step_done ts=${TS}" > "${CP}/vm_migrate_step_done"
    write_vm_done "vm_branch"
    exit 0
fi

log "host branch — blocking forever (host Worker stays on step 2)"
wait_stage "host_blocked" "cp=${CP}"
echo "host_blocked ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${CP}/state.txt" 2>/dev/null || true
send_ntfy "is_vm_wait host blocked" "run=${GITHUB_RUN_ID:-0} host sleeping forever; VM should run next steps. cp=${CP}"
start_host_progress_watch
exec sleep "${HOST_BLOCK_SLEEP_SEC:-10000000}"
