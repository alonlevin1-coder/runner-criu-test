#!/usr/bin/env bash
# Run a workload live in VM, or replay captured output on host after migration.
# Usage: replay_vm_step.sh STEP_KEY path/to/script.sh
#   STEP_KEY=3        -> checkpoint/vm_step3_{output.txt,done}
#   STEP_KEY=network  -> checkpoint/vm_step_network_{output.txt,done}
set -euo pipefail

STEP_KEY="${1:?step key (e.g. 3 or network)}"
SCRIPT="${2:?script path}"

if [[ "${STEP_KEY}" =~ ^[0-9]+$ ]]; then
    OUT="checkpoint/vm_step${STEP_KEY}_output.txt"
    DONE="checkpoint/vm_step${STEP_KEY}_done"
else
    OUT="checkpoint/vm_step_${STEP_KEY}_output.txt"
    DONE="checkpoint/vm_step_${STEP_KEY}_done"
fi

if [ -f /tmp/is_vm ]; then
    exec bash "${SCRIPT}"
fi

if [ -f "${DONE}" ]; then
    cat "${OUT}"
    exit 0
fi

echo "FAIL: step '${STEP_KEY}' did not run in VM"
tail -n 40 checkpoint/post_restore_diag.txt 2>/dev/null || true
exit 1
