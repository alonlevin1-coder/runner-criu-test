#!/usr/bin/env bash
set -euo pipefail

WS="${GITHUB_WORKSPACE:-.}"
ROOT="${WS}/output/r21-fs"
rm -rf "${ROOT}"
mkdir -p "${ROOT}/deep/nested/dir"

PAYLOAD="r21-filesystem-$(date +%s)-$$"
echo "${PAYLOAD}" > "${ROOT}/deep/nested/dir/payload.txt"
echo "mirror" > "${ROOT}/mirror.txt"
ln -sf "deep/nested/dir/payload.txt" "${ROOT}/link.txt"

echo "=== Tree ==="
find "${ROOT}" -type f -o -type l | sort

echo "=== Permissions ==="
chmod 640 "${ROOT}/deep/nested/dir/payload.txt"
stat "${ROOT}/deep/nested/dir/payload.txt"

echo "=== Read back ==="
cat "${ROOT}/link.txt"
SUM="$(sha256sum "${ROOT}/deep/nested/dir/payload.txt" | awk '{print $1}')"
echo "sha256=${SUM}"

CP="${RUNNER_VM_CHECKPOINT:-checkpoint}"
CP="$(cd "${CP}" 2>/dev/null && pwd || echo "${CP}")"
MARKER="${CP}/r21_fs_marker.txt"
echo "written_from_vm ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) sum=${SUM}" > "${MARKER}"
echo "Checkpoint marker: ${MARKER}"
cat "${MARKER}"

echo "Filesystem checks completed."
