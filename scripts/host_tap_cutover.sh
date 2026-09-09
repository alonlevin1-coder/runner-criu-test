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

# Remove workload IP from host NIC so guest can own it.
# ip -o output: "2: r30_dum    inet 10.200.1.2/24 ..."
while read -r dev cidr; do
    [ -n "${dev}" ] || continue
    [ -n "${cidr}" ] || continue
    run ip addr del "${cidr}" dev "${dev}" 2>/dev/null || true
    log "removed ${cidr} from ${dev}"
done < <(ip -o addr show to "${LOCAL_IP}" 2>/dev/null | awk '{print $2, $4}' || true)

run ip tuntap del mode tap "${TAP_DEV}" 2>/dev/null || true
run ip tuntap add mode tap "${TAP_DEV}" user "$(id -un)"
run ip link set "${TAP_DEV}" up
run ip addr add "${TAP_HOST_IP}/${PREFIX}" dev "${TAP_DEV}"
run ip route replace "${LOCAL_IP}/32" dev "${TAP_DEV}"
run sysctl -w net.ipv4.ip_forward=1
run sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
run sysctl -w net.ipv4.conf."${HOST_DEV}".rp_filter=0 2>/dev/null || true
run iptables -I FORWARD 1 -i "${TAP_DEV}" -j ACCEPT 2>/dev/null || true
run iptables -I FORWARD 1 -o "${TAP_DEV}" -j ACCEPT 2>/dev/null || true

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

if ip -o addr show to "${LOCAL_IP}" 2>/dev/null | grep -q .; then
    log "ERROR: LOCAL_IP still on host after cutover"
    exit 1
fi

echo "tap" > "${CHECKPOINT_DIR}/net_mode.txt"
echo "host_tap_cutover=yes tap_dev=${TAP_DEV}" >> "${CHECKPOINT_DIR}/state.txt"
chmod a+rw "${CHECKPOINT_DIR}/net_mode.txt" 2>/dev/null || true
log "cutover OK"
