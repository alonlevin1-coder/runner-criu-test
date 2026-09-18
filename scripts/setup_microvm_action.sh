#!/usr/bin/env bash
# scripts/setup_microvm_action.sh
# Driver script for the MicroVM Migration composite action.
# Sets up host prerequisites, initiates CRIU checkpoint/migration, and handles the
# host/guest split so all subsequent workflow steps execute inside the MicroVM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="$(cd "${ACTION_DIR:-${SCRIPT_DIR}/..}" && pwd)"

T9_T0="$(date +%s)"
T9_LAST="${T9_T0}"
log() { echo "[setup_microvm_action] $(date '+%Y-%m-%d %H:%M:%S') $*"; }
stage() {
    local now
    now="$(date +%s)"
    log "stage=${1} elapsed=$((now - T9_T0))s delta=$((now - T9_LAST))s ${2:-}"
    T9_LAST="${now}"
}

# shellcheck source=is_in_vm.sh
. "${SCRIPT_DIR}/is_in_vm.sh"

if is_in_vm; then
    log "Already executing inside MicroVM (procfs/hostname guest signal). Succeeded."
    exit 0
fi

log "Initializing MicroVM migration from ${ACTION_DIR}..."

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

apt_install() {
    export DEBIAN_FRONTEND=noninteractive
    if [ "$(id -u)" -eq 0 ]; then
        apt-get install -y -q --no-install-recommends -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$@"
    else
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$@"
    fi
}
apt_update() {
    export DEBIAN_FRONTEND=noninteractive
    if [ "$(id -u)" -eq 0 ]; then
        apt-get update -y -q
    else
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -y -q
    fi
}

ensure_qemu() {
    local DEB_DIR="${ACTION_DIR}/appliance/debs"
    local INSTALLED_FROM_DEBS=0
    local pkg deb
    local NEW_DEBS=()
    local VENDOR_DEBS=()
    shopt -s nullglob
    VENDOR_DEBS=("${DEB_DIR}"/*.deb)
    shopt -u nullglob
    for deb in "${VENDOR_DEBS[@]}"; do
        pkg="$(dpkg-deb -f "${deb}" Package 2>/dev/null || true)"
        [ -n "${pkg}" ] || continue
        case "${pkg}" in
            libc6|libselinux1|libssl3|libgcc-s1|libstdc++6) continue ;;
        esac
        if dpkg -s "${pkg}" >/dev/null 2>&1; then
            continue
        fi
        NEW_DEBS+=("${deb}")
    done
    if [ "${#NEW_DEBS[@]}" -gt 0 ]; then
        log "Installing ${#NEW_DEBS[@]} missing vendored debs (skipped already-installed)"
        if run_root dpkg -i "${NEW_DEBS[@]}" \
            || run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q -f --no-install-recommends \
                -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"; then
            INSTALLED_FROM_DEBS=1
        else
            log "Vendored debs failed; falling back to apt"
        fi
        stage "vendor_debs"
    elif [ "${#VENDOR_DEBS[@]}" -gt 0 ]; then
        log "All vendored deb packages already installed"
        INSTALLED_FROM_DEBS=1
        stage "vendor_debs"
    fi

    local NEEDED_PACKAGES=()
    if [ "${INSTALLED_FROM_DEBS}" -eq 0 ]; then
        local p
        for p in qemu-system-x86 cpio gcc dropbear-bin openssh-client iproute2; do
            if ! dpkg -s "${p}" >/dev/null 2>&1; then
                NEEDED_PACKAGES+=("${p}")
            fi
        done
    fi
    if [ "${#NEEDED_PACKAGES[@]}" -gt 0 ]; then
        log "Installing missing system packages: ${NEEDED_PACKAGES[*]}"
        if ! apt_install "${NEEDED_PACKAGES[@]}"; then
            log "apt install missed indexes; updating and retrying"
            apt_update
            apt_install "${NEEDED_PACKAGES[@]}"
        fi
        stage "apt_packages"
    fi
}

ensure_criu() {
    local CRIU_BIN=""
    local c
    for c in "${ACTION_DIR}/bin/criu" /usr/sbin/criu /usr/local/sbin/criu; do
        if [ -x "${c}" ]; then
            CRIU_BIN="${c}"
            break
        fi
    done
    [ -z "${CRIU_BIN}" ] && CRIU_BIN="$(command -v criu || true)"

    if [ -n "${CRIU_BIN}" ] && [ "${CRIU_BIN}" != /usr/sbin/criu ]; then
        log "Installing bundled CRIU to /usr/sbin (guest restore uses host /usr overlay)"
        run_root install -m 755 "${CRIU_BIN}" /usr/sbin/criu
        CRIU_BIN="/usr/sbin/criu"
    fi

    if [ -z "${CRIU_BIN}" ] || [ ! -x "${CRIU_BIN}" ]; then
        log "CRIU binary not found. Building CRIU from source with expanded XSAVE buffers..."
        chmod +x "${ACTION_DIR}/scripts/build_criu.sh"
        "${ACTION_DIR}/scripts/build_criu.sh"
        CRIU_BIN="$(command -v criu || true)"
        [ -x /usr/sbin/criu ] && CRIU_BIN="/usr/sbin/criu"
    fi
    log "Using CRIU binary: ${CRIU_BIN} ($("${CRIU_BIN}" --version 2>/dev/null || true))"
    stage "criu"
}

ensure_criu_libs() {
    local CRIU_BIN="${1:-/usr/sbin/criu}"
    if [ -x "${CRIU_BIN}" ] && command -v ldd >/dev/null && ldd "${CRIU_BIN}" 2>/dev/null | grep -q 'not found'; then
        log "CRIU missing shared libraries; installing runtime packages"
        if ! apt_install libprotobuf-c1 libnet1 libnftables1 libbsd0 libnl-3-200; then
            apt_update
            apt_install libprotobuf-c1 libnet1 libnftables1 libbsd0 libnl-3-200
        fi
        stage "criu_libs"
    fi
}

ensure_daemonize() {
    if [ ! -x "${ACTION_DIR}/scripts/daemonize" ]; then
        log "Compiling daemonize helper..."
        gcc -O2 -Wall "${ACTION_DIR}/scripts/daemonize.c" -o "${ACTION_DIR}/scripts/daemonize"
        chmod +x "${ACTION_DIR}/scripts/daemonize"
    fi
}

ensure_initramfs() {
    local dest="${ACTION_DIR}/appliance/initramfs.cpio.gz"
    if [ -s "${dest}" ]; then
        log "initramfs already present $(ls -lh "${dest}" | awk '{print $5}')"
        stage "initramfs"
        return 0
    fi
    # Network fetch is opt-in: GH release pulls hung the migrate step.
    if [ -n "${T9_INITRAMFS_URL:-}" ]; then
        local url sha tmp got
        local stamp="${ACTION_DIR}/bin/initramfs.release.txt"
        url="${T9_INITRAMFS_URL}"
        sha="${T9_INITRAMFS_SHA256:-}"
        if [ -z "${sha}" ] && [ -f "${stamp}" ]; then
            sha="$(awk -F= '/^sha256=/{print substr($0,8)}' "${stamp}")"
        fi
        tmp="${dest}.part"
        mkdir -p "$(dirname "${dest}")"
        log "Downloading initramfs from ${url}"
        if curl -fsSL --connect-timeout 15 --max-time 60 -o "${tmp}" "${url}"; then
            got="$(sha256sum "${tmp}" | awk '{print $1}')"
            if [ -n "${sha}" ] && [ "${got}" != "${sha}" ]; then
                log "initramfs checksum mismatch; assembling"
                rm -f "${tmp}"
            else
                mv -f "${tmp}" "${dest}"
                log "initramfs download ok $(ls -lh "${dest}" | awk '{print $5}')"
                stage "initramfs"
                return 0
            fi
        else
            log "initramfs download failed; assembling"
            rm -f "${tmp}"
        fi
    fi
    chmod +x "${ACTION_DIR}/appliance/assemble_initramfs.sh"
    "${ACTION_DIR}/appliance/assemble_initramfs.sh"
    stage "initramfs"
}

pack_var_seed() {
    chmod +x "${ACTION_DIR}/scripts/map_host_var.sh" "${ACTION_DIR}/scripts/pack_host_var.sh"
    log "Mapping host /var (deny runtime/cache/images, copy remaining tool state)..."
    "${ACTION_DIR}/scripts/map_host_var.sh" "${CHECKPOINT_DIR}/var_map.txt" || true
    log "Exploding COPY /var trees into checkpoint/var_seed for the guest overlay..."
    if [ "$(id -u)" -eq 0 ]; then
        "${ACTION_DIR}/scripts/pack_host_var.sh" "${CHECKPOINT_DIR}"
    else
        sudo "${ACTION_DIR}/scripts/pack_host_var.sh" "${CHECKPOINT_DIR}"
    fi
    stage "var_seed"
}

extract_dropbear_from_deb() {
    local deb d bin key
    deb="$(ls "${ACTION_DIR}"/appliance/debs/dropbear-bin_*.deb 2>/dev/null | head -n1 || true)"
    [ -n "${deb}" ] || return 0
    d="${ACTION_DIR}/appliance/staging-dropbear"
    rm -rf "${d}"
    mkdir -p "${d}"
    dpkg-deb -x "${deb}" "${d}"
    bin="$(find "${d}" -type f -name dropbear | head -n1 || true)"
    key="$(find "${d}" -type f -name dropbearkey | head -n1 || true)"
    if [ -n "${bin}" ]; then
        export DROPBEAR_BIN="${bin}"
        export DROPBEARKEY_BIN="${key}"
        log "dropbear from ${deb} -> ${DROPBEAR_BIN}"
    fi
}

wait_bg() {
    local name="$1" pid="$2" max="${3:-90}" elapsed=0 rc=0
    while kill -0 "${pid}" 2>/dev/null; do
        if [ "${elapsed}" -ge "${max}" ]; then
            log "ERROR: background ${name} pid=${pid} exceeded ${max}s; killing"
            kill -9 "${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true
            return 124
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if ! wait "${pid}"; then
        rc=$?
        log "ERROR: background ${name} pid=${pid} exited ${rc}"
        return "${rc}"
    fi
    log "background ${name} pid=${pid} ok"
}

chmod +x "${ACTION_DIR}"/scripts/*.sh "${ACTION_DIR}"/appliance/*.sh 2>/dev/null || true
chmod 600 "${ACTION_DIR}/appliance/ssh_id_ed25519" 2>/dev/null || true

CHECKPOINT_DIR="${RUNNER_VM_CHECKPOINT:-${CHECKPOINT_DIR:-${GITHUB_WORKSPACE:-/tmp}/checkpoint}}"
LOG_DIR="${LOG_DIR:-${GITHUB_WORKSPACE:-/tmp}/smoke-logs}"
mkdir -p "${CHECKPOINT_DIR}" "${LOG_DIR}"
tr -d '[:space:]' < /proc/sys/kernel/random/boot_id > "${CHECKPOINT_DIR}/host_boot_id"
cat /proc/cmdline > "${CHECKPOINT_DIR}/host_cmdline" 2>/dev/null || true
chmod a+rw "${CHECKPOINT_DIR}/host_boot_id" "${CHECKPOINT_DIR}/host_cmdline" 2>/dev/null || true
log "Checkpoint dir: ${CHECKPOINT_DIR} host_boot_id=$(cat "${CHECKPOINT_DIR}/host_boot_id")"

log "Host setup in parallel: assemble + /var pack + QEMU dpkg (no overlapping apt)"
ensure_criu
extract_dropbear_from_deb
ensure_daemonize
ensure_initramfs &
PID_INITRAMFS=$!
pack_var_seed &
PID_VAR=$!
ensure_qemu
ensure_criu_libs /usr/sbin/criu
wait_bg initramfs "${PID_INITRAMFS}" 90
wait_bg var_seed "${PID_VAR}" 90
if [ ! -s "${ACTION_DIR}/appliance/initramfs.cpio.gz" ]; then
    log "ERROR: initramfs.cpio.gz missing"
    exit 1
fi
if [ ! -s "${CHECKPOINT_DIR}/var_seed/var/lib/dpkg/status" ]; then
    log "ERROR: var_seed/var/lib/dpkg/status missing"
    exit 1
fi
stage "host_setup"

CRIU_TCP_MODE="${INPUT_TCP_MODE:-${CRIU_TCP_MODE:-established}}"
echo "${CRIU_TCP_MODE}" > "${CHECKPOINT_DIR}/criu_tcp_mode.txt"
chmod a+rw "${CHECKPOINT_DIR}/criu_tcp_mode.txt" 2>/dev/null || true
log "TCP mode configured: ${CRIU_TCP_MODE}"

STEP_SHELL_PID="${STEP_SHELL_PID:-$$}"
echo "${STEP_SHELL_PID}" > "${CHECKPOINT_DIR}/step_shell.pid"
echo "${STEP_SHELL_PID}" > "${CHECKPOINT_DIR}/freeze_exclude_pids.txt"
chmod a+rw "${CHECKPOINT_DIR}/step_shell.pid" "${CHECKPOINT_DIR}/freeze_exclude_pids.txt" 2>/dev/null || true

log "Mapping runner process tree..."
"${ACTION_DIR}/scripts/map_workflow_processes.sh" "${CHECKPOINT_DIR}" "${STEP_SHELL_PID}"

WORKER_PID=$(pgrep -f 'Runner\.Worker' | head -n1 || true)
if [ -z "${WORKER_PID}" ]; then
    log "ERROR: Runner.Worker PID could not be found."
    exit 1
fi
log "Identified Runner.Worker PID: ${WORKER_PID}"

export ALLOW_WORKER_DUMP=1
export KEEP_QEMU_ALIVE=1
export CRIU_TCP_MODE="${CRIU_TCP_MODE}"
export ISOLATE_HOST_TCP_AFTER_DUMP=1
export ACTIVATE_TAP_IMMEDIATELY=1
export QEMU_SMP="${INPUT_SMP:-${QEMU_SMP:-2}}"
export QEMU_MEM="${INPUT_MEMORY_MB:-${QEMU_MEM:-4096}}"
export NTFY_TOPIC="${INPUT_NTFY_TOPIC:-${NTFY_TOPIC:-}}"
export STEP_SHELL_PID

SERIAL_LOG="${LOG_DIR}/vm_serial.log"
log "Daemonizing migration helper (target_pid=${WORKER_PID}, tcp_mode=${CRIU_TCP_MODE})..."
if [ "$(id -u)" -eq 0 ]; then
    "${ACTION_DIR}/scripts/daemonize" \
        "${ACTION_DIR}/scripts/smoke_is_vm_helper.sh" \
        "${WORKER_PID}" \
        "${CHECKPOINT_DIR}" \
        "${ACTION_DIR}" \
        "${SERIAL_LOG}" \
        "worker"
else
    sudo -E "${ACTION_DIR}/scripts/daemonize" \
        "${ACTION_DIR}/scripts/smoke_is_vm_helper.sh" \
        "${WORKER_PID}" \
        "${CHECKPOINT_DIR}" \
        "${ACTION_DIR}" \
        "${SERIAL_LOG}" \
        "worker"
fi

export RUNNER_VM_CHECKPOINT="${CHECKPOINT_DIR}"
export IS_VM_MAX_WAIT_SEC="${IS_VM_MAX_WAIT_SEC:-600}"
log "Awaiting microVM migration cutover and restore..."
"${ACTION_DIR}/scripts/is_vm_wait.sh"
stage "migrated"
