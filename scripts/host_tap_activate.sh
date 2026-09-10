#!/usr/bin/env bash
# Host TAP activate: install TC ingress redirect and remove CRIU drop rules
# Called immediately AFTER guest criu restore completes to prevent early TCP RSTs.
set -euo pipefail

CHECKPOINT_DIR="${1:?checkpoint dir}"
SPEC="${CHECKPOINT_DIR}/network_spec.env"
LOG="${CHECKPOINT_DIR}/host_tap_activate.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [activate] $*" | tee -a "${LOG}"; }

if [ ! -f "${SPEC}" ]; then
    log "missing ${SPEC}"
    exit 1
fi
# shellcheck disable=SC1090
source "${SPEC}"

: > "${LOG}"
log "activating TC redirect for sports=${WORKER_SPORTS:-${WORKER_SPORT:-}} to TAP_DEV=${TAP_DEV}"

run() {
    log "+ $*"
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo -n "$@"
    fi
}

# Ensure ingress qdisc on host physical interface
run tc qdisc add dev "${HOST_DEV}" ingress 2>/dev/null || true

# Setup tc ingress redirect on host eth0: intercept inbound packets for worker sports
# and redirect directly to TAP with TCP/IP checksum recalculation.
SPORTS_TO_REDIRECT="${WORKER_SPORTS:-${WORKER_SPORT:-}}"
for sport in ${SPORTS_TO_REDIRECT}; do
    [ -n "${sport}" ] || continue
    log "installing tc ingress redirect: ${HOST_DEV} dport=${sport} -> ${TAP_DEV}"
    run tc filter add dev "${HOST_DEV}" parent ffff: protocol ip prio 1 u32 \
        match ip protocol 6 0xff \
        match ip dport "${sport}" 0xffff \
        action csum ip tcp \
        action mirred egress redirect dev "${TAP_DEV}" 2>/dev/null || \
    run tc filter add dev "${HOST_DEV}" parent ffff: protocol ip prio 1 u32 \
        match ip protocol 6 0xff \
        match ip dport "${sport}" 0xffff \
        action mirred egress redirect dev "${TAP_DEV}" 2>/dev/null || true
done

# Remove CRIU 0xC114 DROP rules so live packets can flow
for chain in INPUT OUTPUT; do
    while read -r rule; do
        [ -n "${rule}" ] || continue
        del_rule="$(echo "${rule}" | sed "s/-A ${chain}/-D ${chain}/")"
        # shellcheck disable=SC2086
        run iptables ${del_rule} 2>/dev/null || true
        log "deleted rule: ${del_rule}"
    done < <(run iptables -S "${chain}" 2>/dev/null | grep -i 0xc114 | grep -i drop || true)
done

echo "tc_redirect_activated=yes sports=${SPORTS_TO_REDIRECT}" >> "${CHECKPOINT_DIR}/state.txt"
log "activation complete: TC redirect active, drop rules removed."
