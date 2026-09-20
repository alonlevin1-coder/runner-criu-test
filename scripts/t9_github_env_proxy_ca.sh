#!/usr/bin/env bash
# Push proxy CA into subsequent GitHub Actions steps via GITHUB_ENV.
# Node actions (upload-artifact, etc.) do not source profile.d; they inherit
# this file. Do not write NODE_OPTIONS — the runner rejects it.
set -euo pipefail
CHECKPOINT="${CHECKPOINT_DIR:-/mnt/checkpoint}"
LEAF="${CHECKPOINT}/proxy-ca-cert.pem"
BUNDLE="${CHECKPOINT}/ca-bundle-with-proxy.pem"
LOG="${CHECKPOINT}/github_env_ca.log"

log() { echo "[t9_github_env_proxy_ca] $*" | tee -a "${LOG}" 2>/dev/null || echo "[t9_github_env_proxy_ca] $*"; }

if [ ! -f "${LEAF}" ]; then
  log "skip: ${LEAF} missing"
  exit 0
fi

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
  fi
done

if [ "${#targets[@]}" -eq 0 ]; then
  log "skip: no GITHUB_ENV path"
  exit 0
fi

written=0
for dest in "${targets[@]}"; do
  dir="$(dirname "${dest}")"
  [ -d "${dir}" ] || continue
  if grep -q '^NODE_EXTRA_CA_CERTS=' "${dest}" 2>/dev/null; then
    continue
  fi
  {
    echo "NODE_EXTRA_CA_CERTS=${LEAF}"
    if [ -f "${BUNDLE}" ]; then
      echo "SSL_CERT_FILE=${BUNDLE}"
      echo "CURL_CA_BUNDLE=${BUNDLE}"
      echo "REQUESTS_CA_BUNDLE=${BUNDLE}"
      echo "AWS_CA_BUNDLE=${BUNDLE}"
      echo "GIT_SSL_CAINFO=${BUNDLE}"
      echo "PIP_CERT=${BUNDLE}"
      echo "npm_config_cafile=${BUNDLE}"
    fi
  } >> "${dest}" 2>/dev/null || continue
  written=$((written + 1))
  log "appended CA env -> ${dest}"
done
log "written=${written} leaf=${LEAF}"
exit 0
