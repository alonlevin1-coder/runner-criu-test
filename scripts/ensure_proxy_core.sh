#!/usr/bin/env bash
# Build host proxy_core during action setup so TAP prepare is not charged for compile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROXY_SRC="${ACTION_DIR}/visibility/proxy_implementation"
BIN="${ACTION_DIR}/bin/proxy_core"

log() { echo "[ensure_proxy_core] $*"; }

if [ -x "${BIN}" ]; then
    log "already present $(ls -lh "${BIN}" | awk '{print $5}')"
    exit 0
fi

if [ ! -f "${PROXY_SRC}/go.mod" ]; then
    log "ERROR: missing ${PROXY_SRC}/go.mod"
    exit 1
fi

if ! command -v go >/dev/null 2>&1; then
    log "go not on PATH; installing golang-go"
    if [ "$(id -u)" -eq 0 ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends golang-go
    else
        sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends golang-go
    fi
fi

mkdir -p "$(dirname "${BIN}")"
log "building ${BIN} (go=$(go version 2>/dev/null || echo unknown))"
(
    cd "${PROXY_SRC}"
    GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}" \
        GOTOOLCHAIN="${GOTOOLCHAIN:-auto}" \
        go build -o "${BIN}" ./4_proxy_core/
)
chmod 755 "${BIN}"
log "built $(ls -lh "${BIN}" | awk '{print $5}')"
