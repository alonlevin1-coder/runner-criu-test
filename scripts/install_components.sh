#!/usr/bin/env bash
# Fetch versioned feature binaries from a (possibly private) GitHub Release.
# Does not clone the feature repo. Source of binaries is T9_COMPONENT_SOURCE:
#   local   — skip (ensure_proxy_core.sh will go build from a sibling tree)
#   release — gh release download from T9_COMPONENTS_REPO @ T9_PROXY_RELEASE
#   auto    — local if ../proxy_implementation exists, else release
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="$(cd "${ACTION_DIR:-${SCRIPT_DIR}/..}" && pwd)"
DEST="${ACTION_DIR}/bin"
mkdir -p "${DEST}"

log() { echo "[install_components] $*"; }

SOURCE="${T9_COMPONENT_SOURCE:-auto}"
REPO="${T9_COMPONENTS_REPO:-}"
PROXY_TAG="${T9_PROXY_RELEASE:-}"
TOKEN="${COMPONENTS_GITHUB_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"

has_local_proxy() {
  [ -n "${T9_PROXY_SRC:-}" ] \
    || [ -f "${ACTION_DIR}/../proxy_implementation/go.mod" ] \
    || [ -f "${ACTION_DIR}/visibility/proxy_implementation/go.mod" ]
}

if [ "${SOURCE}" = "auto" ]; then
  if has_local_proxy; then
    SOURCE="local"
  else
    SOURCE="release"
  fi
fi
log "source=${SOURCE} repo=${REPO:-none} proxy_tag=${PROXY_TAG:-none}"

if [ "${SOURCE}" = "local" ]; then
  log "skip download (local/monorepo tree)"
  exit 0
fi

if [ "${SOURCE}" != "release" ]; then
  log "ERROR: T9_COMPONENT_SOURCE must be auto|local|release"
  exit 2
fi

need=0
[ -x "${DEST}/proxy_core" ] || need=1
[ -x "${DEST}/t9-ca-inject" ] || need=1
if [ "${need}" -eq 0 ]; then
  log "already have proxy_core and t9-ca-inject in ${DEST}"
  exit 0
fi

if [ -z "${REPO}" ] || [ -z "${PROXY_TAG}" ]; then
  log "ERROR: release mode needs T9_COMPONENTS_REPO (owner/name) and T9_PROXY_RELEASE (e.g. proxy-v0.1.0)"
  exit 1
fi
if [ -z "${TOKEN}" ]; then
  log "ERROR: GH_TOKEN or GITHUB_TOKEN required to read private releases"
  exit 1
fi
export GH_TOKEN="${TOKEN}"

TMP="$(mktemp -d "${RUNNER_TEMP:-/tmp}/t9-rel.XXXXXX")"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT

log "downloading ${PROXY_TAG} from ${REPO}"
if command -v gh >/dev/null 2>&1; then
  gh release download "${PROXY_TAG}" --repo "${REPO}" --dir "${TMP}" \
    --pattern 'proxy_core' --pattern 't9-ca-inject' --pattern 'SHA256SUMS' \
    --clobber
else
  log "ERROR: gh CLI not found (GitHub-hosted runners have it)"
  exit 1
fi

if [ -f "${TMP}/SHA256SUMS" ]; then
  (cd "${TMP}" && sha256sum -c SHA256SUMS)
else
  log "WARN: no SHA256SUMS in release ${PROXY_TAG}"
fi

install -m 755 "${TMP}/proxy_core" "${DEST}/proxy_core"
install -m 755 "${TMP}/t9-ca-inject" "${DEST}/t9-ca-inject"
log "installed proxy_core=$(ls -lh "${DEST}/proxy_core" | awk '{print $5}') t9-ca-inject=$(ls -lh "${DEST}/t9-ca-inject" | awk '{print $5}')"
