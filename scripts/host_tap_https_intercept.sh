#!/usr/bin/env bash
# Steer guest TCP/443 into the host L7 proxy via TAP PREROUTING REDIRECT.
# Does not use OUTPUT uid REDIRECT (that would catch host processes).
# Established GitHub websocket remotes are RETURN'd so the job channel stays direct.
set -euo pipefail

CHECKPOINT_DIR="${1:?checkpoint dir}"
SPEC="${CHECKPOINT_DIR}/network_spec.env"
LOG="${CHECKPOINT_DIR}/host_https_intercept.log"
COMMENT="t9-https-intercept"
LISTEN_PORT="${T9_PROXY_PORT:-8080}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [https-intercept] $*" | tee -a "${LOG}"; }

if [ ! -f "${SPEC}" ]; then
    log "ERROR: missing ${SPEC}"
    exit 1
fi
# shellcheck disable=SC1090
source "${SPEC}"

TAP_DEV="${TAP_DEV:?}"
TAP_HOST_IP="${TAP_HOST_IP:-192.168.100.1}"

run() {
    log "+ $*"
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo -n "$@"
    fi
}

flush_commented() {
    local table="$1" chain="$2"
    local line del
    while read -r line; do
        [ -n "${line}" ] || continue
        del="$(echo "${line}" | sed "s/^-A ${chain}/-D ${chain}/")"
        # shellcheck disable=SC2086
        run iptables -t "${table}" ${del} 2>/dev/null || true
    done < <(run iptables -t "${table}" -S "${chain}" 2>/dev/null | grep -F "${COMMENT}" || true)
}

flush_commented nat PREROUTING
flush_commented filter INPUT

run sysctl -w "net.ipv4.conf.${TAP_DEV}.route_localnet=1" 2>/dev/null || true

EXEMPT_IPS="$(echo "${PROXY_EXEMPT_DSTS:-}" | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u | tr '\n' ' ')"
if [ -z "${EXEMPT_IPS// }" ]; then
    log "ERROR: PROXY_EXEMPT_DSTS empty; refusing to intercept 443 (would steal GHA websocket)"
    exit 1
fi
log "exempt dest IPs: ${EXEMPT_IPS}"

# REDIRECT first at head, then insert RETURN rules in front so they win.
run iptables -t nat -I PREROUTING 1 -i "${TAP_DEV}" -p tcp --dport 443 \
    -m comment --comment "${COMMENT}" \
    -j REDIRECT --to-ports "${LISTEN_PORT}"

idx=1
for ip in ${EXEMPT_IPS}; do
    run iptables -t nat -I PREROUTING "${idx}" -i "${TAP_DEV}" -p tcp --dport 443 -d "${ip}" \
        -m comment --comment "${COMMENT}" -j RETURN
    idx=$((idx + 1))
done

run iptables -I INPUT 1 -i "${TAP_DEV}" -p tcp --dport "${LISTEN_PORT}" \
    -m comment --comment "${COMMENT}" -j ACCEPT

echo "${EXEMPT_IPS}" > "${CHECKPOINT_DIR}/proxy_exempt_dsts.txt"
echo "https_intercept=yes tap=${TAP_DEV} port=${LISTEN_PORT} exempt=${EXEMPT_IPS}" >> "${CHECKPOINT_DIR}/state.txt"
log "installed TAP :443 REDIRECT -> ${TAP_HOST_IP}:${LISTEN_PORT}"
run iptables -t nat -S PREROUTING | grep -F "${COMMENT}" | tee -a "${LOG}" || true
