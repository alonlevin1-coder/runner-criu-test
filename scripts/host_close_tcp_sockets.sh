#!/usr/bin/env bash
# Close host TCP sockets for migrating process tree while frozen under CRIU DROP rules.
# Prevents dual-socket transmission and TCP sequence number divergence.
set -euo pipefail

CHECKPOINT_DIR="${1:?checkpoint dir}"
PIDFILE="${CHECKPOINT_DIR}/sigstopped_pids.txt"
SPEC="${CHECKPOINT_DIR}/network_spec.env"
LOG="${CHECKPOINT_DIR}/host_tcp_close.log"
CLOSE_SEC="${TCP_CLOSE_TIMEOUT_SEC:-15}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [tcp_close] $*" | tee -a "${LOG}"; }

: > "${LOG}"
log "closing host TCP sockets for checkpoint ${CHECKPOINT_DIR}"

if ! command -v ss >/dev/null 2>&1; then
    log "ss not found, skipping socket close"
    echo "host_tcp_sockets_closed=skipped reason=no_ss" >> "${CHECKPOINT_DIR}/state.txt"
    exit 0
fi

SUDO=()
if [ "$(id -u)" -ne 0 ]; then
    SUDO=(sudo -n)
fi

closed=0

# 1. Close sockets discovered by pid in sigstopped_pids.txt
if [ -f "${PIDFILE}" ]; then
    while read -r pid; do
        [ -n "${pid}" ] || continue
        while read -r line; do
            [ -n "${line}" ] || continue
            raw_addr="$(awk '{print $4}' <<< "${line}")"
            sport=""
            if [[ "${raw_addr}" =~ ^\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|[0-9a-fA-F:]+)\]:([0-9]+)$ ]]; then
                sport="${BASH_REMATCH[2]}"
            elif [[ "${raw_addr}" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$ ]]; then
                sport="${BASH_REMATCH[2]}"
            else
                sport="$(sed 's/.*://' <<< "${raw_addr}")"
            fi
            [ -n "${sport}" ] || continue
            log "closing pid=${pid} sport=:${sport} ${line}"
            if timeout "${CLOSE_SEC}" "${SUDO[@]}" ss -t -H -K "sport = :${sport}" >> "${LOG}" 2>&1; then
                closed=$((closed + 1))
            else
                log "WARN: ss -K timed out or failed for sport=:${sport}"
            fi
        done < <(timeout 30 "${SUDO[@]}" ss -H -antp 2>/dev/null | grep -F "pid=${pid}," || true)
    done < "${PIDFILE}"
fi

# 2. Also explicitly close all ports from network_spec.env (WORKER_SPORTS)
if [ -f "${SPEC}" ]; then
    # shellcheck disable=SC1090
    source "${SPEC}"
    SPORTS_TO_CLOSE="${WORKER_SPORTS:-${WORKER_SPORT:-}}"
    for sport in ${SPORTS_TO_CLOSE}; do
        [ -n "${sport}" ] || continue
        # Pre-install DROP rules in INPUT and OUTPUT to prevent host RST packets
        "${SUDO[@]}" iptables -I INPUT 1 -p tcp --dport "${sport}" -j DROP 2>/dev/null || true
        "${SUDO[@]}" iptables -I OUTPUT 1 -p tcp --sport "${sport}" -j DROP 2>/dev/null || true
        log "closing explicit WORKER_SPORT=:${sport}"
        if timeout "${CLOSE_SEC}" "${SUDO[@]}" ss -t -H -K "sport = :${sport}" >> "${LOG}" 2>&1; then
            closed=$((closed + 1))
        fi
    done
fi

echo "host_tcp_sockets_closed=yes count=${closed}" >> "${CHECKPOINT_DIR}/state.txt"
log "host TCP sockets closed: count=${closed}"
