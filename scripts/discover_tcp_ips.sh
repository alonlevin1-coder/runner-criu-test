#!/usr/bin/env bash
# Discover established TCP local IPs for a process tree (Porter F09 pre-dump).
set -euo pipefail

ROOT_PID="${1:?root pid}"
CHECKPOINT_DIR="${2:?checkpoint dir}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=freeze_snapshot_files.sh
source "${SCRIPT_DIR}/freeze_snapshot_files.sh"

CHECKPOINT_DIR="$(cd "${CHECKPOINT_DIR}" && pwd)"
OUT_IPS="${CHECKPOINT_DIR}/tcp_local_ips.txt"
OUT_SS="${CHECKPOINT_DIR}/tcp_estab_ss.txt"
OUT_SPEC="${CHECKPOINT_DIR}/network_spec.env"
PREFLIGHT="${CHECKPOINT_DIR}/r30_preflight.txt"

: > "${OUT_IPS}"
: > "${OUT_SS}"

{
    echo "=== discover_tcp_ips root_pid=${ROOT_PID} ==="
    echo "=== ip addr eth0 ==="
    ip -o addr show dev eth0 2>/dev/null || true
    echo "=== ip route ==="
    ip route 2>/dev/null || true
} >> "${PREFLIGHT}" 2>/dev/null || true

while read -r pid; do
    [ -n "${pid}" ] || continue
    ss -H -tanp 2>/dev/null | grep -F "pid=${pid}," | grep -F ESTAB >> "${OUT_SS}" || true
done < <(collect_tree_pids "${ROOT_PID}")

if [ ! -s "${OUT_SS}" ]; then
    echo "discover_tcp_ips: no ESTAB sockets in tree" >> "${PREFLIGHT}"
    exit 0
fi

declare -A seen=()
while read -r line; do
    [ -n "${line}" ] || continue
    local_ip_port="$(echo "${line}" | awk '{print $4}')"
    local_ip="${local_ip_port%%:*}"
    case "${local_ip}" in
        ""|0.0.0.0|127.0.0.1|::1) continue ;;
    esac
    seen["${local_ip}"]=1
done < "${OUT_SS}"

for ip in "${!seen[@]}"; do
    echo "${ip}" >> "${OUT_IPS}"
done

if [ ! -s "${OUT_IPS}" ]; then
    echo "discover_tcp_ips: no non-loopback local IPs" >> "${PREFLIGHT}"
    exit 0
fi

LOCAL_IP="$(head -n1 "${OUT_IPS}")"
CIDR="$(ip -o addr show to "${LOCAL_IP}" 2>/dev/null | awk '{print $4}' | head -n1 || true)"
if [ -z "${CIDR}" ]; then
    CIDR="$(ip -o addr show dev eth0 2>/dev/null | awk '/inet / {print $4; exit}')"
fi
PREFIX="${CIDR#*/}"
HOST_DEV="$(ip -o addr show to "${LOCAL_IP}" 2>/dev/null | awk '{print $2}' | head -n1 || echo eth0)"
# TAP side address on same prefix (host side of /32 route; guest default gateway).
IFS=. read -r o1 o2 o3 o4 <<< "${LOCAL_IP}"
case "${PREFIX:-24}" in
    8)  TAP_HOST_IP="${o1}.0.0.254" ;;
    16) TAP_HOST_IP="${o1}.${o2}.0.254" ;;
    *)  TAP_HOST_IP="${o1}.${o2}.${o3}.254" ;;
esac
HOST_GW="${TAP_HOST_IP}"

TAP_DEV="tap_t9_${ROOT_PID}"

case "${PREFIX:-24}" in
    8)  NETMASK=255.0.0.0 ;;
    16) NETMASK=255.255.0.0 ;;
    24) NETMASK=255.255.255.0 ;;
    *)  NETMASK=255.255.255.0 ;;
esac

cat > "${OUT_SPEC}" <<EOF
LOCAL_IP=${LOCAL_IP}
PREFIX=${PREFIX:-24}
NETMASK=${NETMASK}
HOST_GW=${HOST_GW}
TAP_HOST_IP=${TAP_HOST_IP}
TAP_DEV=${TAP_DEV}
HOST_DEV=${HOST_DEV}
EOF
chmod a+rw "${OUT_IPS}" "${OUT_SS}" "${OUT_SPEC}" 2>/dev/null || true

{
    echo "=== tcp_local_ips ==="
    cat "${OUT_IPS}"
    echo "=== network_spec.env ==="
    cat "${OUT_SPEC}"
    echo "=== tcp_estab_ss (head) ==="
    head -n 20 "${OUT_SS}"
} >> "${PREFLIGHT}" 2>/dev/null || true

echo "discover_tcp_ips: primary=${LOCAL_IP} prefix=${PREFIX} tap=${TAP_DEV}"
