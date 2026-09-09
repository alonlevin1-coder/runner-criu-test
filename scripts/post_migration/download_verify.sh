#!/usr/bin/env bash
set -euo pipefail

WS="${GITHUB_WORKSPACE:-.}"
DEST="${WS}/output/r21-download"
mkdir -p "${DEST}"

URL="https://httpbin.org/bytes/4096"
OUT="${DEST}/httpbin-4k.bin"

echo "Downloading ${URL}"
curl -fsSL --max-time 25 -o "${OUT}" "${URL}"

BYTES="$(wc -c < "${OUT}" | tr -d ' ')"
SUM="$(sha256sum "${OUT}" | awk '{print $1}')"

echo "Saved ${OUT}"
echo "bytes=${BYTES} sha256=${SUM}"
if command -v xxd >/dev/null 2>&1; then
    xxd "${OUT}" | head -n 3
else
    od -An -tx1 "${OUT}" | head -n 3
fi

if [ "${BYTES}" -lt 1000 ]; then
    echo "ERROR: download too small"
    exit 1
fi

echo "Download verify completed."
