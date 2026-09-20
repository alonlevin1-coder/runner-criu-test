#!/usr/bin/env bash
# Load prebuilt process/socket eBPF objects (no clang/BCC at runtime).
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

CHECKPOINT="${CHECKPOINT_DIR:-/mnt/checkpoint}"
export CHECKPOINT_DIR="${CHECKPOINT}"
SHARE="${T9_EBPF_DIR:-/usr/local/share/t9-ebpf}"
if [ ! -f "${SHARE}/monitor.bpf.o" ] && [ -f "${CHECKPOINT}/ebpf/monitor.bpf.o" ]; then
  SHARE="${CHECKPOINT}/ebpf"
fi
LOG="${CHECKPOINT}/lineage.log"
AGENT_LOG="${CHECKPOINT}/lineage_agent.log"
STATE="${CHECKPOINT}/state.txt"

BIN=""
for candidate in \
    /usr/local/sbin/t9-lineage \
    "${SHARE}/t9-lineage" \
    "${CHECKPOINT}/t9-lineage" \
    "${CHECKPOINT}/ebpf/t9-lineage"
do
  if [ -x "${candidate}" ]; then
    BIN="${candidate}"
    break
  fi
done
if [ -z "${BIN}" ]; then
  echo "FAIL: t9-lineage binary missing" | tee -a "${AGENT_LOG}"
  exit 1
fi
if [ ! -f "${SHARE}/monitor.bpf.o" ] || [ ! -f "${SHARE}/tracer.bpf.o" ]; then
  echo "FAIL: prebuilt BPF objects missing in ${SHARE}" | tee -a "${AGENT_LOG}"
  ls -la "${SHARE}" >> "${AGENT_LOG}" 2>/dev/null || true
  exit 1
fi

mkdir -p /sys/fs/bpf /sys/fs/cgroup /sys/kernel/debug /sys/kernel/tracing
mountpoint -q /sys/fs/cgroup || mount -t cgroup2 cgroup2 /sys/fs/cgroup || true
mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf || true
mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug || true
mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing || true

: > "${LOG}"
chmod a+rw "${LOG}" 2>/dev/null || true
nohup setsid "${BIN}" \
  --monitor "${SHARE}/monitor.bpf.o" \
  --tracer "${SHARE}/tracer.bpf.o" \
  --cgroup /sys/fs/cgroup \
  --log-file "${LOG}" \
  --state-file "${STATE}" \
  >> "${AGENT_LOG}" 2>&1 < /dev/null &
echo $! > "${CHECKPOINT}/lineage.pid"
disown $! 2>/dev/null || true

WAIT="${T9_LINEAGE_WAIT:-0}"
if [ "${WAIT}" -le 0 ]; then
  echo "[GUEST] t9 lineage loader started pid=$(cat "${CHECKPOINT}/lineage.pid")"
  exit 0
fi
ok=0
for _ in $(seq 1 "${WAIT}"); do
  if grep -q "Unified Agent started successfully" "${AGENT_LOG}" 2>/dev/null; then
    ok=1
    break
  fi
  if [ -f "${CHECKPOINT}/lineage.pid" ] && ! kill -0 "$(cat "${CHECKPOINT}/lineage.pid")" 2>/dev/null; then
    echo "WARN: lineage loader exited" | tee -a "${AGENT_LOG}"
    tail -n 40 "${AGENT_LOG}" || true
    exit 1
  fi
  sleep 1
done
if [ "${ok}" -ne 1 ]; then
  echo "WARN: lineage loader did not report start" | tee -a "${AGENT_LOG}"
  tail -n 40 "${AGENT_LOG}" || true
  exit 1
fi
echo "[GUEST] t9 lineage loader ready"
