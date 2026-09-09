#!/usr/bin/env bash
set -euo pipefail

WS="${GITHUB_WORKSPACE:-.}"
DEST="${WS}/output/r21-download"
mkdir -p "${DEST}"

URL="https://raw.githubusercontent.com/github/gitignore/main/Global/GNUmakefile.gitignore"
OUT="${DEST}/gnu-makefile.gitignore"

echo "Downloading ${URL}"
curl -fsSL --max-time 25 -o "${OUT}" "${URL}"

BYTES="$(wc -c < "${OUT}" | tr -d ' ')"
LINES="$(wc -l < "${OUT}" | tr -d ' ')"
SUM="$(sha256sum "${OUT}" | awk '{print $1}')"

echo "Saved ${OUT}"
echo "bytes=${BYTES} lines=${LINES} sha256=${SUM}"
head -n 5 "${OUT}"

if [ "${BYTES}" -lt 10 ]; then
    echo "ERROR: download too small"
    exit 1
fi

echo "Download verify completed."
