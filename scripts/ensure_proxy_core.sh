#!/usr/bin/env bash
# Ensure host proxy_core and guest t9-ca-inject.
# Prefer a GitHub Release (decoupled feature repo); else go build from a sibling tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="$(cd "${ACTION_DIR:-${SCRIPT_DIR}/..}" && pwd)"
BIN="${ACTION_DIR}/bin/proxy_core"
INJECT_BIN="${ACTION_DIR}/bin/t9-ca-inject"

log() { echo "[ensure_proxy_core] $*"; }

chmod +x "${SCRIPT_DIR}/install_components.sh"
"${SCRIPT_DIR}/install_components.sh"

if [ -x "${BIN}" ] && [ -x "${INJECT_BIN}" ]; then
    log "ready proxy_core=$(ls -lh "${BIN}" | awk '{print $5}') t9-ca-inject=$(ls -lh "${INJECT_BIN}" | awk '{print $5}')"
    exit 0
fi

if [ -n "${T9_PROXY_SRC:-}" ]; then
    PROXY_SRC="${T9_PROXY_SRC}"
elif [ -f "${ACTION_DIR}/../proxy_implementation/go.mod" ]; then
    PROXY_SRC="$(cd "${ACTION_DIR}/../proxy_implementation" && pwd)"
elif [ -f "${ACTION_DIR}/visibility/proxy_implementation/go.mod" ]; then
    PROXY_SRC="$(cd "${ACTION_DIR}/visibility/proxy_implementation" && pwd)"
else
    log "ERROR: no binaries and no local proxy_implementation (set T9_COMPONENT_SOURCE=release + T9_COMPONENTS_REPO + T9_PROXY_RELEASE)"
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
log "building from ${PROXY_SRC} (go=$(go version 2>/dev/null || echo unknown))"
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
