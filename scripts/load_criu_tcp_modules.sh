#!/usr/bin/env bash
# Load kernel modules CRIU needs for --tcp-established dump/restore.
set -euo pipefail

if [ "${CRIU_TCP_MODE:-established}" = "close" ]; then
    exit 0
fi

for mod in nfnetlink nf_tables inet_diag tcp_diag; do
    sudo modprobe "${mod}" 2>/dev/null || modprobe "${mod}" 2>/dev/null || true
done
