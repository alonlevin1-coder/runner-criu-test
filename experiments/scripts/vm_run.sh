#!/usr/bin/env bash
# Run a shell command in the migration VM with live stdout/stderr (SSH to kept-alive QEMU).
# Usage: vm_run.sh 'sleep 10; echo lalalal'
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: vm_run.sh <shell-command>" >&2
    exit 2
fi

CMD="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CP="${RUNNER_VM_CHECKPOINT:-${REPO_DIR}/checkpoint}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_KEY="${REPO_DIR}/appliance/ssh_id_ed25519"
WS="${GITHUB_WORKSPACE:-${REPO_DIR}}"

if [ -f /tmp/is_vm ]; then
    cd "${WS}"
    exec bash -lc "${CMD}"
fi

[ -f "${CP}/helper_done" ] || { echo "vm_run: migration helper not finished" >&2; exit 1; }
[ "$(cat "${CP}/restore.rc" 2>/dev/null)" = "0" ] || { echo "vm_run: restore failed" >&2; exit 1; }
[ -f "${CP}/qemu.pid" ] || { echo "vm_run: missing qemu.pid (was KEEP_QEMU_ALIVE=1 set?)" >&2; exit 1; }
kill -0 "$(cat "${CP}/qemu.pid")" 2>/dev/null || { echo "vm_run: QEMU not running" >&2; exit 1; }

SSH=(ssh -i "${SSH_KEY}" -p "${SSH_PORT}" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=5 \
    root@127.0.0.1)

exec "${SSH[@]}" "cd $(printf '%q' "${WS}") && bash -lc $(printf '%q' "${CMD}")"
