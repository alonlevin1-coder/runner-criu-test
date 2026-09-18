#!/usr/bin/env bash
# Explode COPY-classified /var trees into checkpoint/var_seed for a guest overlay.
set -euo pipefail
CP="${1:?checkpoint dir}"
LIST="${CP}/var_copy.list"
DEST="${CP}/var_seed"
STAGE="${CP}/var_seed.building"
MAX_BYTES="${VAR_SEED_MAX_BYTES:-1610612736}" # 1.5 GiB

if [ ! -s "${LIST}" ]; then
    echo "[pack_host_var] no ${LIST}; skipping"
    exit 0
fi

echo "[pack_host_var] exploding $(wc -l < "${LIST}") paths to ${DEST} (excluding apt lists/locks)"

rm -rf "${STAGE}" "${DEST}"
mkdir -p "${STAGE}"

# One pass: copy listed host paths into the seed tree (no tar for the guest).
tar --format=gnu --ignore-failed-read \
    --exclude='var/lib/apt/lists' \
    --exclude='var/lib/apt/periodic' \
    --exclude='var/lib/dpkg/lock' \
    --exclude='var/lib/dpkg/lock-frontend' \
    --exclude='var/lib/dpkg/updates/*' \
    --exclude='var/lib/dpkg/tmp.ci' \
    -C / -cf - -T "${LIST}" | tar -C "${STAGE}" -xf - || {
    echo "[pack_host_var] WARN explode rc=$?; continuing if dpkg status exists"
}

rm -f "${STAGE}/var/lib/dpkg/lock" "${STAGE}/var/lib/dpkg/lock-frontend" 2>/dev/null || true
rm -rf "${STAGE}/var/lib/dpkg/updates" "${STAGE}/var/lib/dpkg/tmp.ci" 2>/dev/null || true
mkdir -p "${STAGE}/var/lib/dpkg/updates" "${STAGE}/var/lib/dpkg/tmp.ci" \
    "${STAGE}/var/run" "${STAGE}/var/lock" "${STAGE}/var/tmp" "${STAGE}/var/log" \
    "${STAGE}/var/cache/apt/archives/partial" "${STAGE}/var/lib/apt/lists/partial"
chmod 1777 "${STAGE}/var/tmp" 2>/dev/null || true

if [ ! -s "${STAGE}/var/lib/dpkg/status" ]; then
    echo "[pack_host_var] ERROR: ${STAGE}/var/lib/dpkg/status missing"
    exit 1
fi

bytes="$(du -sb "${STAGE}" 2>/dev/null | awk '{print $1}')"
echo "[pack_host_var] seed $(awk -v n="${bytes:-0}" 'BEGIN{
    if (n>=1073741824) printf "%.1f GiB", n/1073741824;
    else printf "%.1f MiB", n/1048576
}')"

if [ "${bytes:-0}" -gt "${MAX_BYTES}" ]; then
    echo "[pack_host_var] ERROR: seed ${bytes} bytes exceeds ${MAX_BYTES}"
    rm -rf "${STAGE}"
    exit 1
fi

mv "${STAGE}" "${DEST}"
chmod -R a+rX "${DEST}" 2>/dev/null || true
touch "${DEST}.ok"
echo "[pack_host_var] done ${DEST}/var/lib/dpkg/status"
ls -ld "${DEST}/var/lib/dpkg" "${DEST}/var/lib/snapd" 2>/dev/null || true
