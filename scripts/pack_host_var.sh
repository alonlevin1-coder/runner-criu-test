#!/usr/bin/env bash
# Pack COPY-classified /var trees into checkpoint/var_seed.tar (ustar for busybox).
set -euo pipefail
CP="${1:?checkpoint dir}"
LIST="${CP}/var_copy.list"
OUT="${CP}/var_seed.tar"
MAX_BYTES="${VAR_SEED_MAX_BYTES:-1610612736}" # 1.5 GiB

if [ ! -s "${LIST}" ]; then
    echo "[pack_host_var] no ${LIST}; skipping"
    exit 0
fi

echo "[pack_host_var] packing $(wc -l < "${LIST}") paths to ${OUT} (excluding apt lists)"

# Skip a second du pass; refuse only if the archive itself exceeds the cap.
tar --format=gnu --ignore-failed-read \
    --exclude='var/lib/apt/lists' \
    --exclude='var/lib/apt/periodic' \
    --exclude='var/lib/dpkg/lock' \
    --exclude='var/lib/dpkg/lock-frontend' \
    --exclude='var/lib/dpkg/updates/*' \
    --exclude='var/lib/dpkg/tmp.ci' \
    -C / -cf "${OUT}" -T "${LIST}" || {
    echo "[pack_host_var] WARN tar rc=$?; continuing if archive exists"
}

if [ ! -f "${OUT}" ]; then
    echo "[pack_host_var] ERROR: archive missing"
    exit 1
fi

bytes="$(stat -c %s "${OUT}" 2>/dev/null || wc -c < "${OUT}")"
echo "[pack_host_var] archive $(awk -v n="${bytes}" 'BEGIN{
    if (n>=1073741824) printf "%.1f GiB", n/1073741824;
    else printf "%.1f MiB", n/1048576
}')"

if [ "${bytes}" -gt "${MAX_BYTES}" ]; then
    echo "[pack_host_var] ERROR: archive ${bytes} bytes exceeds ${MAX_BYTES}; refusing to fill guest tmpfs"
    rm -f "${OUT}"
    exit 1
fi

chmod a+r "${OUT}"
ls -lh "${OUT}"
echo "[pack_host_var] done"
