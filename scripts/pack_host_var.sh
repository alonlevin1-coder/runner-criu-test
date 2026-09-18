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

echo "[pack_host_var] exploding $(wc -l < "${LIST}") paths to ${DEST} (no snapd/snap; those are 9p)"

rm -rf "${STAGE}" "${DEST}"
mkdir -p "${STAGE}"

copy_one() {
    local rel="$1"
    case "${rel}" in
        var/lib/snapd|var/lib/snapd/*|var/snap|var/snap/*) return 0 ;;
    esac
    [ -e "/${rel}" ] || return 0
    mkdir -p "${STAGE}/$(dirname "${rel}")"
    cp -a --reflink=auto "/${rel}" "${STAGE}/${rel}" 2>/dev/null \
        || cp -a "/${rel}" "${STAGE}/${rel}"
}

export STAGE
while read -r rel; do
    [ -n "${rel}" ] || continue
    copy_one "${rel}"
done < "${LIST}"

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

mv "${STAGE}" "${DEST}"
chmod a+rX "${DEST}" "${DEST}/var" "${DEST}/var/lib" "${DEST}/var/lib/dpkg" 2>/dev/null || true
touch "${DEST}.ok"
echo "[pack_host_var] done ${DEST}/var/lib/dpkg/status"

rm -f "${CP}/snapd_9p" "${CP}/var_snap_9p"
if grep -qx 'var/lib/snapd' "${LIST}" 2>/dev/null && [ -d /var/lib/snapd ]; then
    echo 1 > "${CP}/snapd_9p"
    echo "[pack_host_var] snapd via 9p (COPY under cap)"
fi
if grep -qx 'var/snap' "${LIST}" 2>/dev/null && [ -d /var/snap ]; then
    echo 1 > "${CP}/var_snap_9p"
    echo "[pack_host_var] /var/snap via 9p"
fi
chmod a+r "${CP}/snapd_9p" "${CP}/var_snap_9p" 2>/dev/null || true
