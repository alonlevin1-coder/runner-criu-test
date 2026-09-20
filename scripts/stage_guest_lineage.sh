#!/usr/bin/env bash
# Copy eBPF sources + 6.17 headers onto the guest-visible checkpoint share.
set -euo pipefail
CHECKPOINT_DIR="${1:?checkpoint dir}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST="${CHECKPOINT_DIR}/ebpf"
mkdir -p "${DEST}/parsers"
cp -a "${ACTION_DIR}/visibility/ebpf/"*.c "${DEST}/"
cp -a "${ACTION_DIR}/visibility/ebpf/"*.py "${DEST}/"
cp -a "${ACTION_DIR}/visibility/ebpf/parsers/"*.py "${DEST}/parsers/"
HDR="${ACTION_DIR}/appliance/ebpf/linux-headers-6.17.0-40-generic.tar.gz"
if [ -f "${HDR}" ]; then
  cp -a "${HDR}" "${CHECKPOINT_DIR}/linux-headers-6.17.0-40-generic.tar.gz"
  cp -a "${HDR}" "${DEST}/linux-headers-6.17.0-40-generic.tar.gz"
fi
cp -a "${SCRIPT_DIR}/guest_start_lineage.sh" "${CHECKPOINT_DIR}/guest_start_lineage.sh"
chmod 755 "${CHECKPOINT_DIR}/guest_start_lineage.sh" "${DEST}/t9_lineage_agent.py"
echo "guest_lineage_staged=yes" >> "${CHECKPOINT_DIR}/state.txt"
