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

bytes=0
while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    [ -e "/${rel}" ] || continue
    n="$(du -sb -x "/${rel}" 2>/dev/null | awk '{print $1}' || true)"
    n="${n:-0}"
    bytes=$((bytes + n))
done < "${LIST}"

echo "[pack_host_var] packing $(wc -l < "${LIST}") paths ($(awk -v n="${bytes}" 'BEGIN{
    if (n>=1073741824) printf "%.1f GiB", n/1073741824;
    else printf "%.1f MiB", n/1048576
}')) to ${OUT}"

if [ "${bytes}" -gt "${MAX_BYTES}" ]; then
    echo "[pack_host_var] ERROR: COPY set ${bytes} bytes exceeds ${MAX_BYTES}; refusing to fill guest tmpfs"
    exit 1
fi

tar --format=gnu --ignore-failed-read -C / -cf "${OUT}" -T "${LIST}" || {
    echo "[pack_host_var] WARN tar rc=$?; continuing if archive exists"
}
chmod a+r "${OUT}"
ls -lh "${OUT}"
echo "[pack_host_var] done"
