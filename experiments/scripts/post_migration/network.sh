#!/usr/bin/env bash
set -euo pipefail

echo "=== DNS resolution ==="
getent hosts example.com
getent hosts github.com || true

echo "=== Default route ==="
ip route show default 2>/dev/null || route -n 2>/dev/null || true

echo "=== Interface addresses ==="
ip -4 addr show scope global 2>/dev/null || ifconfig 2>/dev/null || true

echo "=== HTTPS GET example.com ==="
curl -fsSL --max-time 15 https://example.com | head -c 200
echo

echo "=== HTTPS GET httpbin.org/get ==="
curl -fsSL --max-time 15 https://httpbin.org/get | head -c 200
echo

echo "=== HTTPS HEAD github.com ==="
curl -fsSI --max-time 15 https://github.com | head -n 6

echo "Network checks completed."
