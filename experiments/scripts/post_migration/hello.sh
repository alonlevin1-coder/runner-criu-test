#!/usr/bin/env bash
set -euo pipefail

echo "Hello World"
echo "Build step completed successfully."
echo "Kernel: $(uname -r)"
echo "Hostname: $(hostname)"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

WS="${GITHUB_WORKSPACE:-.}"
mkdir -p "${WS}/output"
{
  echo "Hello World"
  echo "Build step completed successfully."
  echo "Kernel: $(uname -r)"
  echo "Hostname: $(hostname)"
} > "${WS}/output/hello.txt"

echo "Wrote ${WS}/output/hello.txt ($(wc -c < "${WS}/output/hello.txt") bytes)"
