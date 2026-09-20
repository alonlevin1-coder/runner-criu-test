#!/usr/bin/env bash
# Stage 1: host-side L7 proxy on the TAP address. No --transparent (TAP PREROUTING is later).
# The handler only logs HTTP metadata; secret injection is out of scope.
set -euo pipefail

CHECKPOINT_DIR="${1:?checkpoint dir}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROXY_SRC="${ACTION_DIR}/visibility/proxy_implementation"
HANDLER="${ACTION_DIR}/visibility/http_log_handler.py"
RULES="${ACTION_DIR}/visibility/rules.yaml"
PROXY_STATE="${CHECKPOINT_DIR}/host_proxy"
# CA private key must not live on the guest-visible checkpoint 9p share.
CA_DIR="${T9_PROXY_CA_DIR:-/tmp/t9-proxy-ca}"
LISTEN_PORT="${T9_PROXY_PORT:-8080}"
HANDLER_HOST="127.0.0.1"
HANDLER_PORT="${T9_PROXY_HANDLER_PORT:-8091}"
HANDLER_LISTEN="${HANDLER_HOST}:${HANDLER_PORT}"
BIN="${ACTION_DIR}/bin/proxy_core"
LOG="${CHECKPOINT_DIR}/host_proxy.log"

mkdir -p "${CHECKPOINT_DIR}" "${PROXY_STATE}" "$(dirname "${BIN}")" "${CA_DIR}" /tmp/t9-proxy
chmod 700 "${CA_DIR}" 2>/dev/null || true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [host-proxy] $*" | tee -a "${LOG}"; }

alive() {
    local pidfile="$1"
    local pid
    [ -f "${pidfile}" ] || return 1
    pid="$(cat "${pidfile}" 2>/dev/null || true)"
    [ -n "${pid}" ] || return 1
    kill -0 "${pid}" 2>/dev/null
}

TAP_HOST_IP="192.168.100.1"
SPEC="${CHECKPOINT_DIR}/network_spec.env"
if [ -f "${SPEC}" ]; then
    # shellcheck disable=SC1090
    source "${SPEC}"
fi
TAP_HOST_IP="${TAP_HOST_IP:-192.168.100.1}"
LISTEN="${TAP_HOST_IP}:${LISTEN_PORT}"

if ! ip -o addr show to "${TAP_HOST_IP}" 2>/dev/null | grep -q .; then
    log "ERROR: TAP address ${TAP_HOST_IP} is not assigned; refusing to bind elsewhere"
    exit 1
fi

ensure_binary() {
    if [ -x "${BIN}" ]; then
        return 0
    fi
    log "proxy_core missing; building via ensure_proxy_core.sh (fallback)"
    chmod +x "${SCRIPT_DIR}/ensure_proxy_core.sh"
    "${SCRIPT_DIR}/ensure_proxy_core.sh"
}

if alive "${PROXY_STATE}/proxy.pid" && alive "${PROXY_STATE}/handler.pid"; then
    log "already running listen=$(cat "${PROXY_STATE}/listen.txt" 2>/dev/null || echo unknown)"
    exit 0
fi

ensure_binary
[ -f "${HANDLER}" ] || { log "ERROR: missing ${HANDLER}"; exit 1; }
[ -f "${RULES}" ] || { log "ERROR: missing ${RULES}"; exit 1; }

HTTP_LOG="${CHECKPOINT_DIR}/http.log"
: > "${HTTP_LOG}" 2>/dev/null || true
chmod a+rw "${HTTP_LOG}" 2>/dev/null || true

if ! alive "${PROXY_STATE}/handler.pid"; then
    log "starting HTTP log handler on ${HANDLER_LISTEN}"
    python3 -u "${HANDLER}" --listen "${HANDLER_LISTEN}" --log-file "${HTTP_LOG}" \
        >> "${CHECKPOINT_DIR}/http_log_handler.log" 2>&1 &
    echo $! > "${PROXY_STATE}/handler.pid"
fi

for i in $(seq 1 50); do
    if python3 -c "import socket; s=socket.create_connection(('${HANDLER_HOST}', int('${HANDLER_PORT}')), 0.2); s.close()" 2>/dev/null; then
        break
    fi
    sleep 0.1
    if [ "${i}" -eq 50 ]; then
        log "ERROR: log handler did not listen on ${HANDLER_LISTEN}"
        tail -n 40 "${CHECKPOINT_DIR}/http_log_handler.log" | tee -a "${LOG}" || true
        exit 1
    fi
done

if ! alive "${PROXY_STATE}/proxy.pid"; then
    log "starting proxy_core listen=${LISTEN} ca=${CA_DIR} (explicit proxy, not transparent)"
    "${BIN}" \
        --listen "${LISTEN}" \
        --rules "${RULES}" \
        --ca-dir "${CA_DIR}" \
        --env-script "${CHECKPOINT_DIR}/proxy_env.sh" \
        >> "${CHECKPOINT_DIR}/proxy_core.log" 2>&1 &
    echo $! > "${PROXY_STATE}/proxy.pid"
fi

ok=0
for i in $(seq 1 80); do
    if grep -q "Proxy started" "${CHECKPOINT_DIR}/proxy_core.log" 2>/dev/null; then
        ok=1
        break
    fi
    if ! alive "${PROXY_STATE}/proxy.pid"; then
        log "ERROR: proxy_core exited"
        tail -n 40 "${CHECKPOINT_DIR}/proxy_core.log" | tee -a "${LOG}" || true
        exit 1
    fi
    sleep 0.1
done
if [ "${ok}" -ne 1 ]; then
    log "ERROR: proxy_core did not report start"
    tail -n 40 "${CHECKPOINT_DIR}/proxy_core.log" | tee -a "${LOG}" || true
    exit 1
fi

# Guest later needs the cert only. Never copy ca-key.pem onto checkpoint 9p.
if [ -f "${CA_DIR}/ca-cert.pem" ]; then
    cp -a "${CA_DIR}/ca-cert.pem" "${CHECKPOINT_DIR}/proxy-ca-cert.pem"
    chmod a+r "${CHECKPOINT_DIR}/proxy-ca-cert.pem" 2>/dev/null || true
fi

echo "${LISTEN}" > "${PROXY_STATE}/listen.txt"
echo "host_proxy=yes listen=${LISTEN} ca_dir=${CA_DIR}" >> "${CHECKPOINT_DIR}/state.txt"
log "ready listen=${LISTEN} http_log=${HTTP_LOG}"
