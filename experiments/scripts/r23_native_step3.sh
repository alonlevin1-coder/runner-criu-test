#!/usr/bin/env bash
# Step 3 for R23 — must run inside VM via restored Worker StepsRunner (not POST_MIGRATION).
set -euo pipefail

CP="${RUNNER_VM_CHECKPOINT:-checkpoint}"
CP="$(cd "${CP}" 2>/dev/null && pwd || echo "${CP}")"

if [ ! -f /tmp/is_vm ]; then
    echo "FAIL: step 3 reached on host — host Worker should be blocked on migrate step"
    exit 1
fi

echo "=== R23 native step 3 in VM ==="
echo "Hello World from VM native StepsRunner step 3"
echo "Kernel: $(uname -r)"
echo "Hostname: $(hostname)"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "${CP}" output
{
    echo "Hello World from VM native StepsRunner step 3"
    echo "Kernel: $(uname -r)"
    echo "Hostname: $(hostname)"
} | tee "${CP}/r23_native_step3.txt" output/r23_native_step3.txt

touch "${CP}/r23_native_step3_done"
sync
