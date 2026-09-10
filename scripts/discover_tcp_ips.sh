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

parse_ss_local_ip() {
    local line="${1:?ss line}"
    local raw="${2:?local addr field}"
    local ip=""

    if [[ "${raw}" =~ ^\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\]:[0-9]+$ ]]; then
        ip="${BASH_REMATCH[1]}"
    elif [[ "${raw}" =~ ^\[::ffff:([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\]:[0-9]+$ ]]; then
        ip="${BASH_REMATCH[1]}"
    elif [[ "${raw}" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):[0-9]+$ ]]; then
        ip="${BASH_REMATCH[1]}"
    else
        echo "discover_tcp_ips: could not parse local addr '${raw}' from: ${line}" >> "${PREFLIGHT}"
        return 1
    fi
    printf '%s' "${ip}"
}

parse_ss_sport() {
    local raw="${1:?local addr field}"
    local sport=""
    if [[ "${raw}" =~ :([0-9]+)$ ]]; then
        sport="${BASH_REMATCH[1]}"
    fi
    printf '%s' "${sport}"
}

declare -A seen=()
declare -A seen_sports=()
while read -r line; do
    [ -n "${line}" ] || continue
    local_ip_port="$(awk '{print $4}' <<< "${line}")"
    [ -n "${local_ip_port}" ] || continue
    local_ip="$(parse_ss_local_ip "${line}" "${local_ip_port}" || true)"
    [ -n "${local_ip}" ] || continue
    case "${local_ip}" in
        0.0.0.0|127.0.0.1) continue ;;
    esac
    seen["${local_ip}"]=1
    sport="$(parse_ss_sport "${local_ip_port}")"
    [ -n "${sport}" ] && seen_sports["${sport}"]=1
done < "${OUT_SS}"

for ip in "${!seen[@]}"; do
    echo "${ip}" >> "${OUT_IPS}"
done

if [ ! -s "${OUT_IPS}" ]; then
    echo "discover_tcp_ips: no non-loopback local IPs" >> "${PREFLIGHT}"
    exit 0
fi

LOCAL_IP="$(head -n1 "${OUT_IPS}")"
if ! [[ "${LOCAL_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "discover_tcp_ips: invalid LOCAL_IP after parse: '${LOCAL_IP}'" >> "${PREFLIGHT}"
    exit 1
fi
CIDR="$(ip -o addr show to "${LOCAL_IP}" 2>/dev/null | awk '{print $4}' | head -n1 || true)"
if [ -z "${CIDR}" ]; then
    CIDR="$(ip -o addr show dev eth0 2>/dev/null | awk '/inet / {print $4; exit}')"
fi
PREFIX="${CIDR#*/}"
HOST_DEV="$(ip -o addr show to "${LOCAL_IP}" 2>/dev/null | awk '{print $2}' | head -n1 || echo eth0)"
ETH0_MAC="$(cat "/sys/class/net/${HOST_DEV}/address" 2>/dev/null || ip link show "${HOST_DEV}" 2>/dev/null | awk '/ether/ {print $2; exit}' || echo "52:54:00:12:34:56")"

# TAP side address on dedicated private bridge subnet.
TAP_HOST_IP="192.168.100.1"
GUEST_IP="192.168.100.2"
TAP_PREFIX="24"
TAP_NETMASK="255.255.255.0"
HOST_GW="${TAP_HOST_IP}"

TAP_DEV="tap_t9_${ROOT_PID}"

case "${PREFIX:-24}" in
    8)  NETMASK=255.0.0.0 ;;
    16) NETMASK=255.255.0.0 ;;
    24) NETMASK=255.255.255.0 ;;
    *)  NETMASK=255.255.255.0 ;;
esac

WORKER_SPORTS="${!seen_sports[*]}"
PRIMARY_SPORT="$(head -n1 <<< "${WORKER_SPORTS// /$'\n'}")"

cat > "${OUT_SPEC}" <<EOF
LOCAL_IP=${LOCAL_IP}
PREFIX=${PREFIX:-24}
NETMASK=${NETMASK}
HOST_GW=${HOST_GW}
HOST_DEV=${HOST_DEV}
ETH0_MAC=${ETH0_MAC}
TAP_DEV=${TAP_DEV}
TAP_HOST_IP=${TAP_HOST_IP}
GUEST_IP=${GUEST_IP}
TAP_PREFIX=${TAP_PREFIX}
TAP_NETMASK=${TAP_NETMASK}
WORKER_SPORTS="${WORKER_SPORTS}"
WORKER_SPORT=${PRIMARY_SPORT}
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

echo "discover_tcp_ips: primary=${LOCAL_IP} prefix=${PREFIX} tap=${TAP_DEV} sports=${WORKER_SPORTS} mac=${ETH0_MAC}"
