#!/usr/bin/env bash
# Porter F09 host TAP cutover: move workload local IP to guest via TAP + /32 route.
set -euo pipefail

CHECKPOINT_DIR="${1:?checkpoint dir}"
SPEC="${CHECKPOINT_DIR}/network_spec.env"
LOG="${CHECKPOINT_DIR}/host_tap_cutover.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [tap] $*" | tee -a "${LOG}"; }

if [ ! -f "${SPEC}" ]; then
    log "missing ${SPEC}"
    exit 1
fi
# shellcheck disable=SC1090
source "${SPEC}"

: > "${LOG}"
log "cutover LOCAL_IP=${LOCAL_IP} TAP_DEV=${TAP_DEV} TAP_HOST_IP=${TAP_HOST_IP}"

run() {
    log "+ $*"
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo -n "$@"
    fi
}

# Setup host TAP device on private bridge subnet without removing host eth0 IP.
# Inbound TCP traffic for Worker established ports is redirected to TAP via tc mirred.
run ip tuntap del mode tap "${TAP_DEV}" 2>/dev/null || true
run ip tuntap add mode tap "${TAP_DEV}" user "$(id -un)"
run ip link set "${TAP_DEV}" up
run ip addr add "${TAP_HOST_IP}/${TAP_PREFIX:-24}" dev "${TAP_DEV}"
run ip route replace "${GUEST_IP:-192.168.100.2}/32" dev "${TAP_DEV}" 2>/dev/null || true

run sysctl -w net.ipv4.ip_forward=1
run sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
run sysctl -w net.ipv4.conf.all.accept_local=1 2>/dev/null || true
run sysctl -w net.ipv4.conf."${HOST_DEV}".rp_filter=0 2>/dev/null || true
run sysctl -w net.ipv4.conf."${TAP_DEV}".rp_filter=0 2>/dev/null || true
run iptables -I FORWARD 1 -i "${TAP_DEV}" -j ACCEPT 2>/dev/null || true
run iptables -I FORWARD 1 -o "${TAP_DEV}" -j ACCEPT 2>/dev/null || true

# Setup tc ingress redirect on host eth0: intercept inbound packets for worker sport
# and redirect directly to TAP before host TCP stack sees them.
run tc qdisc add dev "${HOST_DEV}" ingress 2>/dev/null || true
SPORTS_TO_REDIRECT="${WORKER_SPORTS:-${WORKER_SPORT:-}}"
for sport in ${SPORTS_TO_REDIRECT}; do
    [ -n "${sport}" ] || continue
    log "installing tc ingress redirect: ${HOST_DEV} dport=${sport} -> ${TAP_DEV}"
    run tc filter add dev "${HOST_DEV}" parent ffff: protocol ip prio 1 u32 \
        match ip protocol 6 0xff \
        match ip dport "${sport}" 0xffff \
        action mirred egress redirect dev "${TAP_DEV}" 2>/dev/null || true
done

# Remove CRIU 0xC114 DROP rules (Porter HostTapManager.cleanup_criu_iptables_rules).
for chain in INPUT OUTPUT; do
    while read -r rule; do
        [ -n "${rule}" ] || continue
        del_rule="$(echo "${rule}" | sed "s/-A ${chain}/-D ${chain}/")"
        # shellcheck disable=SC2086
        run iptables ${del_rule} 2>/dev/null || true
        log "deleted rule: ${del_rule}"
    done < <(run iptables -S "${chain}" 2>/dev/null | grep -i 0xc114 | grep -i drop || true)
done

if ! ip -o addr show to "${LOCAL_IP}" 2>/dev/null | grep -q .; then
    log "ERROR: LOCAL_IP missing from host after cutover"
    exit 1
fi

echo "tap" > "${CHECKPOINT_DIR}/net_mode.txt"
echo "host_tap_cutover=yes tap_dev=${TAP_DEV} tc_redirect=yes sports=${SPORTS_TO_REDIRECT}" >> "${CHECKPOINT_DIR}/state.txt"
chmod a+rw "${CHECKPOINT_DIR}/net_mode.txt" 2>/dev/null || true
log "cutover OK (eth0 IP preserved, tc redirect active for sports: ${SPORTS_TO_REDIRECT})"
