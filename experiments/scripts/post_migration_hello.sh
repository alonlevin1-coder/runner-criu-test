#!/usr/bin/env bash
# Post-migration workload — intentionally normal-looking step output (no VM banners).
set -euo pipefail

CP="${RUNNER_VM_CHECKPOINT:-checkpoint}"
CP="$(cd "${CP}" 2>/dev/null && pwd || echo "${CP}")"

echo "Hello World"
echo "Build step completed successfully."
echo "Kernel: $(uname -r)"
echo "Hostname: $(hostname)"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p output "${CP}"
{
  echo "Hello World"
  echo "Build step completed successfully."
  echo "Kernel: $(uname -r)"
  echo "Hostname: $(hostname)"
} > output/hello.txt

cp output/hello.txt "${CP}/vm_step3_output.txt"
touch "${CP}/vm_step3_done"
sync
