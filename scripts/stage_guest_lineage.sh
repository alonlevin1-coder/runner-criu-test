#!/usr/bin/env bash
# Copy prebuilt eBPF objects + t9-lineage onto the guest-visible checkpoint share.
set -euo pipefail
CHECKPOINT_DIR="${1:?checkpoint dir}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST="${CHECKPOINT_DIR}/ebpf"
mkdir -p "${DEST}"
cp -a "${ACTION_DIR}/visibility/ebpf/prebuilt/"*.bpf.o "${DEST}/"
if [ -x "${ACTION_DIR}/bin/t9-lineage" ]; then
  cp -a "${ACTION_DIR}/bin/t9-lineage" "${DEST}/t9-lineage"
  cp -a "${ACTION_DIR}/bin/t9-lineage" "${CHECKPOINT_DIR}/t9-lineage"
  chmod 755 "${DEST}/t9-lineage" "${CHECKPOINT_DIR}/t9-lineage"
fi
cp -a "${SCRIPT_DIR}/guest_start_lineage.sh" "${CHECKPOINT_DIR}/guest_start_lineage.sh"
chmod 755 "${CHECKPOINT_DIR}/guest_start_lineage.sh"
echo "guest_lineage_staged=yes" >> "${CHECKPOINT_DIR}/state.txt"
