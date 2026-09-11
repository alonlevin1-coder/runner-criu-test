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
HOST_DEVS="$(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^(eth|en)' || echo "${HOST_DEV}")"
for dev in ${HOST_DEVS}; do
    run sysctl -w net.ipv4.conf."${dev}".rp_filter=0 2>/dev/null || true
    run sysctl -w net.ipv4.conf."${dev}".accept_local=1 2>/dev/null || true
done
run sysctl -w net.ipv4.conf."${TAP_DEV}".rp_filter=0 2>/dev/null || true
run sysctl -w net.ipv4.conf."${TAP_DEV}".accept_local=1 2>/dev/null || true
run iptables -I FORWARD 1 -i "${TAP_DEV}" -j ACCEPT 2>/dev/null || true
run iptables -I FORWARD 1 -o "${TAP_DEV}" -j ACCEPT 2>/dev/null || true
run iptables -I INPUT 1 -i "${TAP_DEV}" -j ACCEPT 2>/dev/null || true
TAP_SUBNET="${TAP_HOST_IP%.*}.0/${TAP_PREFIX:-24}"
for dev in ${HOST_DEVS}; do
    run iptables -t nat -I POSTROUTING 1 -s "${TAP_SUBNET}" -o "${dev}" -j MASQUERADE 2>/dev/null || true
done
log "installed iptables MASQUERADE for ${TAP_SUBNET} out ${HOST_DEVS}"

CRIU_SPORTS="$(run iptables -S INPUT 2>/dev/null | grep -i 0xc114 | grep -oE -- '--dport [0-9]+' | awk '{print $2}' | sort -u || true)"
SPORTS_TO_REDIRECT="$(echo "${WORKER_SPORTS:-${WORKER_SPORT:-}} ${CRIU_SPORTS:-}" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u | tr '\n' ' ')"
log "ports to redirect (spec + criu): ${SPORTS_TO_REDIRECT}"

log "activating TC ingress redirect immediately across host interfaces: ${HOST_DEVS}"
for dev in ${HOST_DEVS}; do
    run tc qdisc add dev "${dev}" ingress 2>/dev/null || true
    for sport in ${SPORTS_TO_REDIRECT}; do
        [ -n "${sport}" ] || continue
        log "installing tc ingress redirect: ${dev} dport=${sport} -> ${TAP_DEV}"
        run tc filter add dev "${dev}" parent ffff: protocol ip prio 1 u32 \
            match ip protocol 6 0xff \
            match ip dport "${sport}" 0xffff \
            action mirred egress redirect dev "${TAP_DEV}" 2>/dev/null || true
    done
done

# Keep host TCP stack completely isolated from the migrated connections:
# 1. Inbound packets reaching host stack (INPUT) are dropped so host never generates RSTs.
# 2. Outbound packets from host kernel (OUTPUT) for these sports (e.g. spurious TCP RSTs) are dropped.
# Note: MicroVM packets traverse the FORWARD chain and are completely unaffected.
for sport in ${SPORTS_TO_REDIRECT}; do
    [ -n "${sport}" ] || continue
    run iptables -I INPUT 1 -p tcp --dport "${sport}" -j DROP 2>/dev/null || true
    run iptables -I OUTPUT 1 -p tcp --sport "${sport}" -j DROP 2>/dev/null || true
    log "installed host isolation DROP rules for sport=${sport}"
done

# Clean up temporary CRIU 0xC114 DROP rules
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

if command -v tcpdump >/dev/null 2>&1; then
    sudo -n tcpdump -i any -n -w "${CHECKPOINT_DIR}/traffic.pcap" "tcp and (port 443 or port 80)" 2>"${CHECKPOINT_DIR}/tcpdump.log" &
    TCPDUMP_PID=$!
    echo "${TCPDUMP_PID}" > "${CHECKPOINT_DIR}/tcpdump.pid"
    log "started tcpdump PID=${TCPDUMP_PID} writing to ${CHECKPOINT_DIR}/traffic.pcap"
fi

echo "tap" > "${CHECKPOINT_DIR}/net_mode.txt"
echo "host_tap_cutover=yes tap_dev=${TAP_DEV} tc_redirect=active sports=${SPORTS_TO_REDIRECT}" >> "${CHECKPOINT_DIR}/state.txt"
chmod a+rw "${CHECKPOINT_DIR}/net_mode.txt" 2>/dev/null || true
log "cutover OK (eth0 IP preserved, tc redirect active on all host devs, sports: ${SPORTS_TO_REDIRECT})"
