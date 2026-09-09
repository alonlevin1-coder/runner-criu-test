#!/usr/bin/env bash
set -euo pipefail

echo "=== DNS resolution ==="
getent hosts github.com || true
getent hosts api.github.com || true

echo "=== Default route ==="
ip route show default 2>/dev/null || route -n 2>/dev/null || true

echo "=== Interface addresses ==="
ip -4 addr show scope global 2>/dev/null || ifconfig 2>/dev/null || true

echo "=== HTTPS HEAD github.com ==="
curl -fsSI --max-time 15 https://github.com | head -n 8

echo "=== GitHub API zen ==="
curl -fsS --max-time 15 https://api.github.com/zen

echo "=== HTTP download (small) ==="
TMP="$(mktemp)"
curl -fsSL --max-time 20 -o "${TMP}" https://api.github.com/repos/octocat/Hello-World/commits?per_page=1
BYTES="$(wc -c < "${TMP}" | tr -d ' ')"
echo "Downloaded ${BYTES} bytes from GitHub API"
head -c 120 "${TMP}"
echo
rm -f "${TMP}"

echo "Network checks completed."
