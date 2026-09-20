#!/usr/bin/env bash
# Build host proxy_core and guest t9-ca-inject during action setup so TAP
# prepare is not charged for compile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROXY_SRC="${ACTION_DIR}/visibility/proxy_implementation"
BIN="${ACTION_DIR}/bin/proxy_core"
INJECT_BIN="${ACTION_DIR}/bin/t9-ca-inject"

log() { echo "[ensure_proxy_core] $*"; }

need_build=0
if [ ! -x "${BIN}" ]; then
    need_build=1
fi
if [ ! -x "${INJECT_BIN}" ]; then
    need_build=1
fi
if [ "${need_build}" -eq 0 ]; then
    log "already present proxy_core=$(ls -lh "${BIN}" | awk '{print $5}') t9-ca-inject=$(ls -lh "${INJECT_BIN}" | awk '{print $5}')"
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
log "building (go=$(go version 2>/dev/null || echo unknown))"
(
    cd "${PROXY_SRC}"
    export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
    export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"
    export CGO_ENABLED=0
    if [ ! -x "${BIN}" ]; then
        go build -o "${BIN}" ./4_proxy_core/
    fi
    if [ ! -x "${INJECT_BIN}" ]; then
        go build -o "${INJECT_BIN}" ./cmd/t9-ca-inject/
    fi
)
chmod 755 "${BIN}" "${INJECT_BIN}"
log "built proxy_core=$(ls -lh "${BIN}" | awk '{print $5}') t9-ca-inject=$(ls -lh "${INJECT_BIN}" | awk '{print $5}')"
