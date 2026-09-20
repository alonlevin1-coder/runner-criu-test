#!/usr/bin/env bash
# Compile monitor/tracer BPF objects against BTF from appliance/bzImage.
# Run when the C sources or kernel image change; commit the resulting .o files.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
EBPF_DIR="${REPO_DIR}/visibility/ebpf"
OUT_DIR="${EBPF_DIR}/prebuilt"
KERNEL_BIN="${REPO_DIR}/appliance/bzImage"
BUILD="/tmp/t9-ebpf-build"
EXTRACT="${REPO_DIR}/scripts/extract-vmlinux"
if [ ! -f "${EXTRACT}" ]; then
  EXTRACT="$(command -v extract-vmlinux || true)"
fi

mkdir -p "${BUILD}" "${OUT_DIR}"
if [ -z "${EXTRACT}" ]; then
  EXTRACT="$(find /usr/src /tmp/t9-kheaders -name extract-vmlinux 2>/dev/null | head -1 || true)"
fi
if [ -z "${EXTRACT}" ] || [ ! -f "${EXTRACT}" ]; then
  python3 - "${KERNEL_BIN}" "${BUILD}/vmlinux" <<'PY'
import sys, re, pathlib
src = pathlib.Path(sys.argv[1]).read_bytes()
# ELF payload after gzip/xz in bzImage; prefer scripts/extract-vmlinux when present.
idx = src.find(b"\x7fELF")
if idx < 0:
    sys.exit("no ELF in bzImage")
pathlib.Path(sys.argv[2]).write_bytes(src[idx:])
print(f"extracted ELF at offset {idx}")
PY
else
  bash "${EXTRACT}" "${KERNEL_BIN}" > "${BUILD}/vmlinux"
fi
bpftool btf dump file "${BUILD}/vmlinux" format c > "${BUILD}/vmlinux.h"
ln -sfn "${BUILD}/vmlinux.h" "${EBPF_DIR}/vmlinux.h"

CLANG="${CLANG:-clang}"
CFLAGS=(
  -O2 -g -target bpf -D__TARGET_ARCH_x86 -D__BPF_TRACING__
  -fno-stack-protector -Wall -Wno-unused-value -Wno-pointer-sign
  -Wno-compare-distinct-pointer-types -Werror
  -I"${BUILD}" -I/usr/include -I/usr/include/x86_64-linux-gnu
)
"${CLANG}" "${CFLAGS[@]}" -c "${EBPF_DIR}/monitor.bpf.c" -o "${OUT_DIR}/monitor.bpf.o"
"${CLANG}" "${CFLAGS[@]}" -c "${EBPF_DIR}/tracer.bpf.c" -o "${OUT_DIR}/tracer.bpf.o"
STRIP="$(command -v llvm-strip-18 || command -v llvm-strip || true)"
if [ -n "${STRIP}" ]; then
  "${STRIP}" -g --keep-section=.BTF --keep-section=.BTF.ext \
    "${OUT_DIR}/monitor.bpf.o" "${OUT_DIR}/tracer.bpf.o" || true
fi
rm -f "${EBPF_DIR}/vmlinux.h"
ls -lh "${OUT_DIR}/monitor.bpf.o" "${OUT_DIR}/tracer.bpf.o"
echo "built ${OUT_DIR}/*.bpf.o against $(basename "${KERNEL_BIN}")"
