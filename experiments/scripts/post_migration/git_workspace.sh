#!/usr/bin/env bash
set -euo pipefail

WS="${GITHUB_WORKSPACE:-.}"
cd "${WS}"

echo "=== Git workspace ==="
echo "pwd=$(pwd)"
echo "branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
echo "commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
git status -sb
echo "tracked_files=$(git ls-files | wc -l | tr -d ' ')"

echo "=== Recent commit ==="
git log -1 --oneline 2>/dev/null || true

echo "=== Write + git diff ==="
MARK="${WS}/output/r21-git-touch.txt"
mkdir -p "${WS}/output"
echo "vm-touch $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${MARK}"
git status --short "${MARK}" || true

echo "Git workspace checks completed."
