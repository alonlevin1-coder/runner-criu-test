#!/usr/bin/env bash
# Load process/socket eBPF filters in the guest (same 6.17 headers as bzImage).
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

CHECKPOINT="${CHECKPOINT_DIR:-/mnt/checkpoint}"
SHARE="${T9_EBPF_DIR:-/usr/local/share/t9-ebpf}"
if [ ! -f "${SHARE}/t9_lineage_agent.py" ] && [ -f "${CHECKPOINT}/ebpf/t9_lineage_agent.py" ]; then
  SHARE="${CHECKPOINT}/ebpf"
fi
LOG="${CHECKPOINT}/lineage.log"
AGENT_LOG="${CHECKPOINT}/lineage_agent.log"
HDR_ROOT=/tmp/t9-kheaders
KVER="6.17.0-40-generic"

mkdir -p /sys/fs/bpf /sys/fs/cgroup /sys/kernel/debug /sys/kernel/tracing "${HDR_ROOT}"
mountpoint -q /sys/fs/cgroup || mount -t cgroup2 cgroup2 /sys/fs/cgroup || true
mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf || true
mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug || true
mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing || true

HDR_TAR=""
for candidate in \
    "${CHECKPOINT}/linux-headers-${KVER}.tar.gz" \
    "${SHARE}/linux-headers-${KVER}.tar.gz" \
    "/ebpf/linux-headers-${KVER}.tar.gz"
do
  if [ -f "${candidate}" ]; then
    HDR_TAR="${candidate}"
    break
  fi
done
if [ -n "${HDR_TAR}" ] && [ ! -d "${HDR_ROOT}/linux-headers-${KVER}" ]; then
  tar -xzf "${HDR_TAR}" -C "${HDR_ROOT}"
fi
if [ -d "${HDR_ROOT}/linux-headers-${KVER}" ]; then
  export BCC_KERNEL_SOURCE="${HDR_ROOT}/linux-headers-${KVER}"
fi

if ! python3 -c "from bcc import BPF" >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -q >/tmp/t9-bcc-apt.log 2>&1 || true
  apt-get install -y -q --no-install-recommends python3-bpfcc clang llvm >/tmp/t9-bcc-apt.log 2>&1 \
    || echo "WARN: could not apt-install python3-bpfcc" | tee -a "${AGENT_LOG}"
fi

: > "${LOG}"
chmod a+rw "${LOG}" 2>/dev/null || true
cd "${SHARE}"
python3 -u "${SHARE}/t9_lineage_agent.py" \
  --monitor-bpf "${SHARE}/monitor.bpf.c" \
  --tracer-bpf "${SHARE}/tracer.bpf.c" \
  --cgroup /sys/fs/cgroup \
  --log-file "${LOG}" \
  >> "${AGENT_LOG}" 2>&1 &
echo $! > "${CHECKPOINT}/lineage.pid"

ok=0
for _ in $(seq 1 90); do
  if grep -q "Unified Agent started successfully" "${AGENT_LOG}" 2>/dev/null; then
    ok=1
    break
  fi
  if [ -f "${CHECKPOINT}/lineage.pid" ] && ! kill -0 "$(cat "${CHECKPOINT}/lineage.pid")" 2>/dev/null; then
    echo "WARN: lineage agent exited during BPF compile" | tee -a "${AGENT_LOG}"
    tail -n 40 "${AGENT_LOG}" || true
    exit 1
  fi
  sleep 1
done
if [ "${ok}" -ne 1 ]; then
  echo "WARN: lineage agent did not report start" | tee -a "${AGENT_LOG}"
  tail -n 40 "${AGENT_LOG}" || true
  exit 1
fi
echo "lineage=yes" >> "${CHECKPOINT}/state.txt"
echo "[GUEST] t9 lineage agent ready"
