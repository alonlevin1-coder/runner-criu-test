#!/usr/bin/env bash
# Local R30 smoke: TAP cutover + criu --tcp-established + QEMU restore.
# Validates T9 scripts without GitHub-hosted runner (Porter F09 topology).
#
# Usage:
#   sudo ./scripts/smoke_r30_local_tcp.sh
#   BUILD=1 sudo ./scripts/smoke_r30_local_tcp.sh
#   STAGE=discover sudo ./scripts/smoke_r30_local_tcp.sh  # no QEMU (fast)
#
# Success (full): peer receives "PONG 101" on the migrated TCP connection.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${REPO_DIR}/scripts"
SMOKE_DIR="${REPO_DIR}/smoke/r30local"
WORK_DIR="${WORK_DIR:-/tmp/r30_local_${USER:-user}_$$}"
CHECKPOINT_DIR="${WORK_DIR}/checkpoint"
SERIAL_LOG="${WORK_DIR}/vm_serial.log"
SSH_PORT="${SSH_PORT:-2222}"
STAGE="${STAGE:-full}"

LOCAL_IP="10.200.1.2"
LOCAL_PORT="45678"
PEER_NS="r30_peer"
VETH_H="r30_vh"
DUMMY="r30_dum"

KERNEL_BIN="${REPO_DIR}/appliance/bzImage"
INITRD_BIN="${REPO_DIR}/appliance/initramfs.cpio.gz"
SSH_KEY="${REPO_DIR}/appliance/ssh_id_ed25519"

PEER_STATUS="${WORK_DIR}/peer_status.txt"
PEER_ACTION="${WORK_DIR}/peer_action.txt"
PEER_REPLY="${WORK_DIR}/peer_reply.txt"
WORKLOAD_STATE="${WORK_DIR}/tcp_status.txt"

QEMU_PID=""
PEER_PID=""
WORKLOAD_PID=""

log() { echo "[$(date '+%H:%M:%S')] [r30-local] $*"; }

run_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n "$@"; fi
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing: $1"; exit 1; }
}

cleanup() {
    [ -n "${QEMU_PID}" ] && kill -9 "${QEMU_PID}" 2>/dev/null || true
    [ -n "${PEER_PID}" ] && kill -9 "${PEER_PID}" 2>/dev/null || true
    [ -n "${WORKLOAD_PID}" ] && kill -9 "${WORKLOAD_PID}" 2>/dev/null || true
    pkill -f "peer_server.py.*${WORK_DIR}" 2>/dev/null || true
    run_root ip netns del "${PEER_NS}" 2>/dev/null || true
    run_root ip link del "${VETH_H}" 2>/dev/null || true
    run_root ip link del "${DUMMY}" 2>/dev/null || true
    if [ -f "${CHECKPOINT_DIR}/network_spec.env" ]; then
        # shellcheck disable=SC1091
        source "${CHECKPOINT_DIR}/network_spec.env"
        run_root ip tuntap del mode tap "${TAP_DEV}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

cleanup_stale() {
    pkill -9 -f "peer_server.py.*r30local" 2>/dev/null || true
    pkill -9 -x workload_tcp 2>/dev/null || true
    run_root ss -t -K "sport = :${LOCAL_PORT}" 2>/dev/null || true
    run_root ip netns del "${PEER_NS}" 2>/dev/null || true
    run_root ip link del "${VETH_H}" 2>/dev/null || true
    run_root ip link del "${DUMMY}" 2>/dev/null || true
    sleep 0.5
}

setup_network() {
    log "peer netns + dummy ${LOCAL_IP}/24"
    run_root ip netns del "${PEER_NS}" 2>/dev/null || true
    run_root ip link del "${VETH_H}" 2>/dev/null || true
    run_root ip link del "${DUMMY}" 2>/dev/null || true
    run_root ip netns add "${PEER_NS}"
    run_root ip link add "${VETH_H}" type veth peer name r30_vp
    run_root ip link set r30_vp netns "${PEER_NS}"
    run_root ip addr add 10.200.0.254/24 dev "${VETH_H}"
    run_root ip link set "${VETH_H}" up
    run_root ip netns exec "${PEER_NS}" ip addr add 10.200.0.1/24 dev r30_vp
    run_root ip netns exec "${PEER_NS}" ip link set r30_vp up
    run_root ip netns exec "${PEER_NS}" ip link set lo up
    run_root ip netns exec "${PEER_NS}" ip route add default via 10.200.0.254
    run_root ip link add "${DUMMY}" type dummy
    run_root ip addr add "${LOCAL_IP}/24" dev "${DUMMY}"
    run_root ip link set "${DUMMY}" up
    run_root sysctl -w net.ipv4.ip_forward=1 >/dev/null
    run_root ip netns exec "${PEER_NS}" ping -c 1 -W 2 "${LOCAL_IP}" >/dev/null
}

start_peer() {
    rm -f "${PEER_STATUS}" "${PEER_ACTION}" "${PEER_REPLY}"
    run_root ip netns exec "${PEER_NS}" python3 "${SMOKE_DIR}/peer_server.py" \
        "${PEER_STATUS}" "${PEER_ACTION}" "${PEER_REPLY}" &
    PEER_PID=$!
    sleep 0.5
}

start_workload() {
    rm -f "${WORKLOAD_STATE}"
    local bin="${WORK_DIR}/workload_tcp"
    gcc -static -O2 -Wall "${SMOKE_DIR}/workload_tcp.c" -o "${bin}"
    # cwd must exist in guest (/tmp); exec avoids extra shell in process tree.
    ( cd /tmp && exec "${bin}" "${WORKLOAD_STATE}" "${WORK_DIR}/tcp_counter.txt" ) \
        </dev/null >/dev/null 2>&1 &
    WORKLOAD_PID=$!
    for _ in $(seq 1 50); do
        [ -f "${WORKLOAD_STATE}" ] && break
        sleep 0.1
    done
    grep -q INITIAL_CONNECTED "${WORKLOAD_STATE}"
    grep -q "CONNECTED ${LOCAL_IP} ${LOCAL_PORT}" "${PEER_STATUS}"
    log "TCP up pid=${WORKLOAD_PID}"
}

ensure_appliance() {
    if [ "${BUILD:-0}" = "1" ] || [ ! -f "${INITRD_BIN}" ]; then
        "${REPO_DIR}/appliance/assemble_initramfs.sh"
    fi
    [ -f "${INITRD_BIN}" ] || { log "ERROR: missing ${INITRD_BIN}"; exit 1; }
    [ -f "${KERNEL_BIN}" ] || { log "ERROR: missing ${KERNEL_BIN}"; exit 1; }
    [ -f "${SSH_KEY}" ] || { log "ERROR: missing ${SSH_KEY}"; exit 1; }
}

dump_and_cutover() {
    export CRIU_TCP_MODE=established
    mkdir -p "${CHECKPOINT_DIR}/dev_shm" "${CHECKPOINT_DIR}/host_tmp"
    : > "${CHECKPOINT_DIR}/state.txt"
    "${SCRIPT_DIR}/discover_tcp_ips.sh" "${WORKLOAD_PID}" "${CHECKPOINT_DIR}"
    grep -q "${LOCAL_IP}" "${CHECKPOINT_DIR}/tcp_local_ips.txt"
    # shellcheck source=freeze_snapshot_files.sh
    source "${SCRIPT_DIR}/freeze_snapshot_files.sh"
    freeze_tree "${CHECKPOINT_DIR}" "${WORKLOAD_PID}"
    echo "host_tree_frozen_forever=yes" >> "${CHECKPOINT_DIR}/state.txt"
    echo "established" > "${CHECKPOINT_DIR}/criu_tcp_mode.txt"
    "${SCRIPT_DIR}/load_criu_tcp_modules.sh"
    local criu_bin
    criu_bin="$(command -v criu || echo /usr/sbin/criu)"
    set +e
    run_root "${criu_bin}" dump -t "${WORKLOAD_PID}" -D "${CHECKPOINT_DIR}" \
        --leave-stopped --shell-job --file-locks --ext-unix-sk --tcp-established \
        --ghost-limit 32M -v4 -o "${CHECKPOINT_DIR}/dump.log"
    local dump_rc=$?
    set -e
    echo "${dump_rc}" > "${CHECKPOINT_DIR}/dump.rc"
    [ "${dump_rc}" -eq 0 ] || {
        log "ERROR: criu dump rc=${dump_rc}"
        tail -n 20 "${CHECKPOINT_DIR}/dump.log" || true
        kill -9 "${WORKLOAD_PID}" 2>/dev/null || true
        exit 1
    }
    close_tree_tcp_sockets "${CHECKPOINT_DIR}"
    "${SCRIPT_DIR}/host_tap_cutover.sh" "${CHECKPOINT_DIR}"
}

boot_qemu_and_restore() {
    # shellcheck disable=SC1091
    source "${CHECKPOINT_DIR}/network_spec.env"
    local runner_home="${WORK_DIR}/host_runner"
    local dotnet_dir="/usr/share/dotnet"
    mkdir -p "${runner_home}"
    [ -d "${dotnet_dir}" ] || dotnet_dir="/tmp"
    local accel="-enable-kvm -cpu host"
    [ -e /dev/kvm ] || accel="-accel tcg -cpu max"
    run_root qemu-system-x86_64 ${accel} -m 2G -smp 2 -display none -monitor none \
        -kernel "${KERNEL_BIN}" -initrd "${INITRD_BIN}" \
        -append "console=ttyS0 panic=1 loglevel=7 net.ifnames=0 rdinit=/init" -no-reboot \
        -netdev "tap,id=net0,ifname=${TAP_DEV},script=no,downscript=no" -device virtio-net-pci,netdev=net0 \
        -netdev "user,id=net1,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" -device virtio-net-pci,netdev=net1 \
        -virtfs "local,path=${CHECKPOINT_DIR},mount_tag=checkpoint,security_model=none" \
        -virtfs "local,path=${WORK_DIR},mount_tag=workdir,security_model=none" \
        -virtfs "local,path=${runner_home},mount_tag=host_runner,security_model=none,readonly=on" \
        -virtfs "local,path=/usr,mount_tag=host_usr,security_model=none,readonly=on" \
        -virtfs "local,path=/bin,mount_tag=host_bin,security_model=none,readonly=on" \
        -virtfs "local,path=/lib,mount_tag=host_lib,security_model=none,readonly=on" \
        -virtfs "local,path=/lib64,mount_tag=host_lib64,security_model=none,readonly=on" \
        -serial "file:${SERIAL_LOG}" &
    QEMU_PID=$!
    local ssh=(ssh -i "${SSH_KEY}" -p "${SSH_PORT}" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -o BatchMode=yes root@127.0.0.1)
    local ssh_ok=0
    for _ in $(seq 1 90); do
        if "${ssh[@]}" 'echo ok' >/dev/null 2>&1; then
            ssh_ok=1
            break
        fi
        kill -0 "${QEMU_PID}" 2>/dev/null || break
        sleep 1
    done
    [ "${ssh_ok}" -eq 1 ] || {
        log "ERROR: SSH failed; serial tail:"
        tail -n 25 "${SERIAL_LOG}" || true
        exit 1
    }
    "${ssh[@]}" "/bin/busybox mkdir -p ${WORK_DIR} && /bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L workdir ${WORK_DIR}"
    "${ssh[@]}" '/t9_restore.sh'
    grep -q "network_reconstruct ok" "${CHECKPOINT_DIR}/guest_progress.txt"
}

verify_tcp() {
    echo "PING" > "${PEER_ACTION}"
    for _ in $(seq 1 60); do
        [ -f "${PEER_REPLY}" ] && break
        sleep 0.5
    done
    [ "$(tr -d '\r\n' < "${PEER_REPLY}")" = "PONG 101" ]
    log "PASS: PONG 101 on migrated TCP"
}

main() {
    need_cmd gcc python3 ip ss criu
    [ "${STAGE}" = "full" ] && need_cmd qemu-system-x86_64
    [ "$(id -u)" -eq 0 ] || sudo -n true
    mkdir -p "${WORK_DIR}" "${CHECKPOINT_DIR}"
    chmod -R a+rwx "${WORK_DIR}" 2>/dev/null || true
    cleanup_stale
    setup_network
    start_peer
    start_workload
    dump_and_cutover
    if [ "${STAGE}" = "discover" ]; then
        log "PASS: discover+dump+TAP (STAGE=discover)"
        exit 0
    fi
    ensure_appliance
    boot_qemu_and_restore
    verify_tcp
}

main "$@"
