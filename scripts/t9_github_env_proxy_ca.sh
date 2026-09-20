#!/usr/bin/env bash
# Push proxy CA into subsequent GitHub Actions steps via GITHUB_ENV.
# After restore this script often runs with guest mounts (empty /tmp) while
# JS actions inherit Runner.Worker's host mount ns — so the env value must be a
# host-visible path. Never write NODE_OPTIONS (the runner rejects it).
set -euo pipefail

log() {
  echo "[t9_github_env_proxy_ca] $*"
}

find_readable() {
  local p
  for p in "$@"; do
    [ -n "${p}" ] || continue
    [ -r "${p}" ] || continue
    echo "${p}"
    return 0
  done
  return 1
}

LEAF_SRC="$(find_readable \
  "${CHECKPOINT_DIR:-}/proxy-ca-cert.pem" \
  /mnt/checkpoint/proxy-ca-cert.pem \
  /tmp/t9-checkpoint/proxy-ca-cert.pem \
  /usr/local/share/ca-certificates/t9-proxy-ca.crt \
  /etc/ssl/certs/t9-proxy-ca.pem \
  /tmp/t9-proxy-ca/ca-cert.pem || true)"

if [ -z "${LEAF_SRC}" ]; then
  log "skip: no readable proxy CA (checkpoint_dir=${CHECKPOINT_DIR:-} mnt=$(ls -l /mnt/checkpoint/proxy-ca-cert.pem 2>&1 || true))"
  exit 0
fi

WS="${GITHUB_WORKSPACE:-}"
if [ -z "${WS}" ]; then
  for pid in /proc/[0-9]*; do
    [ -r "${pid}/environ" ] || continue
    cmd="$(tr '\0' ' ' < "${pid}/cmdline" 2>/dev/null || true)"
    echo "${cmd}" | grep -q 'Runner.Worker' || continue
    WS="$(tr '\0' '\n' < "${pid}/environ" 2>/dev/null | sed -n 's/^GITHUB_WORKSPACE=//p' | head -n1 || true)"
    [ -n "${WS}" ] && break
  done
fi

install_copy() {
  local dest="$1"
  local dir
  dir="$(dirname "${dest}")"
  mkdir -p "${dir}" 2>/dev/null || return 1
  cp -a "${LEAF_SRC}" "${dest}" 2>/dev/null || cp "${LEAF_SRC}" "${dest}" 2>/dev/null || return 1
  chmod a+r "${dest}" 2>/dev/null || true
  [ -r "${dest}" ]
}

LEAF_PUB=""
for dest in \
  "${WS:+${WS}/.t9-proxy-ca.pem}" \
  /tmp/t9-checkpoint/proxy-ca-cert.pem \
  /mnt/checkpoint/proxy-ca-cert.pem
do
  [ -n "${dest}" ] || continue
  if [ -r "${dest}" ] || install_copy "${dest}"; then
    LEAF_PUB="${dest}"
    break
  fi
done
LEAF_PUB="${LEAF_PUB:-${LEAF_SRC}}"

# Host-ns Node (upload-artifact) cannot see guest /mnt or /usr. Prefer workspace
# then the host checkpoint path that 9p is backed by.
LEAF_FOR_NODE="${LEAF_PUB}"
if [ -n "${WS}" ] && [ -r "${WS}/.t9-proxy-ca.pem" ]; then
  LEAF_FOR_NODE="${WS}/.t9-proxy-ca.pem"
elif [ -r /tmp/t9-checkpoint/proxy-ca-cert.pem ]; then
  LEAF_FOR_NODE="/tmp/t9-checkpoint/proxy-ca-cert.pem"
fi

BUNDLE_SRC="$(find_readable \
  "${CHECKPOINT_DIR:-}/ca-bundle-with-proxy.pem" \
  /mnt/checkpoint/ca-bundle-with-proxy.pem \
  /tmp/t9-checkpoint/ca-bundle-with-proxy.pem \
  /etc/ssl/certs/ca-certificates.crt || true)"

targets=()
if [ -n "${GITHUB_ENV:-}" ]; then
  targets+=("${GITHUB_ENV}")
fi
for pid in /proc/[0-9]*; do
  [ -r "${pid}/environ" ] || continue
  cmd="$(tr '\0' ' ' < "${pid}/cmdline" 2>/dev/null || true)"
  echo "${cmd}" | grep -qE 'Runner\.Worker|is_vm_wait|setup_microvm' || continue
  ge="$(tr '\0' '\n' < "${pid}/environ" 2>/dev/null | sed -n 's/^GITHUB_ENV=//p' | head -n1 || true)"
  [ -n "${ge}" ] || continue
  targets+=("${ge}")
  if [ -d "${pid}/root" ]; then
    targets+=("${pid}/root${ge}")
    if [ -n "${WS}" ]; then
      install_copy "${pid}/root${WS}/.t9-proxy-ca.pem" || true
    fi
    install_copy "${pid}/root/tmp/t9-checkpoint/proxy-ca-cert.pem" || true
  fi
done

if [ "${#targets[@]}" -eq 0 ]; then
  log "skip: no GITHUB_ENV path (leaf_src=${LEAF_SRC})"
  exit 0
fi

written=0
for dest in "${targets[@]}"; do
  dir="$(dirname "${dest}")"
  [ -d "${dir}" ] || continue
  if grep -q '^NODE_EXTRA_CA_CERTS=' "${dest}" 2>/dev/null; then
    log "already set in ${dest}"
    continue
  fi
  {
    echo "NODE_EXTRA_CA_CERTS=${LEAF_FOR_NODE}"
    if [ -n "${BUNDLE_SRC}" ]; then
      echo "SSL_CERT_FILE=${BUNDLE_SRC}"
      echo "CURL_CA_BUNDLE=${BUNDLE_SRC}"
      echo "REQUESTS_CA_BUNDLE=${BUNDLE_SRC}"
      echo "AWS_CA_BUNDLE=${BUNDLE_SRC}"
      echo "GIT_SSL_CAINFO=${BUNDLE_SRC}"
      echo "PIP_CERT=${BUNDLE_SRC}"
      echo "npm_config_cafile=${BUNDLE_SRC}"
    fi
  } >> "${dest}" 2>/dev/null || continue
  written=$((written + 1))
  log "appended CA env -> ${dest}"
done
log "written=${written} leaf_src=${LEAF_SRC} leaf_node=${LEAF_FOR_NODE}"
exit 0
