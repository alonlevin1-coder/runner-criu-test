#!/usr/bin/env bash
# Build/download ubuntu-22.04 artifacts that every GH-hosted migrate can reuse.
# Run on ubuntu-22.04 (GitHub-hosted). Do not run on Noble — glibc/QEMU ABI must match Jammy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEB_DIR="${ROOT}/appliance/debs"
BIN_DIR="${ROOT}/bin"
export DEBIAN_FRONTEND=noninteractive

mkdir -p "${DEB_DIR}" "${BIN_DIR}"
rm -f "${DEB_DIR}"/*.deb

sudo apt-get update -y -q
sudo apt-get install -y -q --no-install-recommends gcc cpio git ca-certificates

download_pkgs() {
    mkdir -p "${DEB_DIR}"
    (cd "${DEB_DIR}" && apt-get download "$@")
}

# Exact --no-install-recommends set from GH ubuntu-22.04 (do not recurse into libc).
QEMU_PKGS=(
    dropbear-bin
    ipxe-qemu
    ipxe-qemu-256k-compat-efi-roms
    libbrlapi0.8
    libcacard0
    libdaxctl1
    libfdt1
    libgstreamer-plugins-base1.0-0
    libibverbs1
    libndctl6
    libnl-route-3-200
    libopus0
    liborc-0.4-0
    libpcsclite1
    libpmem1
    librdmacm1
    libspice-server1
    libtomcrypt1
    liburing2
    libusbredirparser1
    qemu-system-common
    qemu-system-data
    qemu-system-x86
    seabios
)

echo "=== Downloading QEMU + dropbear debs ==="
download_pkgs "${QEMU_PKGS[@]}"

echo "=== Building patched CRIU ==="
chmod +x "${ROOT}/scripts/build_criu.sh"
"${ROOT}/scripts/build_criu.sh"
sudo install -m 755 /usr/sbin/criu "${BIN_DIR}/criu"
ldd /usr/sbin/criu | tee "${BIN_DIR}/criu.ldd.txt"

echo "=== Downloading CRIU runtime library packages (skip libc/libssl) ==="
mapfile -t CRIU_LIBS < <(ldd /usr/sbin/criu | awk '/=> \// {print $3}')
CRIU_PKGS=()
for lib in "${CRIU_LIBS[@]}"; do
    pkg="$(dpkg -S "${lib}" 2>/dev/null | awk -F: '{print $1}' | head -n1 || true)"
    case "${pkg}" in
        ''|libc6|libssl3|libgcc-s1|libstdc++6|gcc-*-base) continue ;;
        *) CRIU_PKGS+=("${pkg}") ;;
    esac
done
if [ "${#CRIU_PKGS[@]}" -gt 0 ]; then
    printf '%s\n' "${CRIU_PKGS[@]}" | sort -u | tee "${BIN_DIR}/criu.pkgs.txt"
    download_pkgs $(printf '%s\n' "${CRIU_PKGS[@]}" | sort -u)
fi

echo "=== Compiling daemonize ==="
gcc -O2 -Wall "${ROOT}/scripts/daemonize.c" -o "${ROOT}/scripts/daemonize"
chmod +x "${ROOT}/scripts/daemonize"

echo "=== Assembling initramfs on this Jammy image ==="
chmod +x "${ROOT}/appliance/assemble_initramfs.sh"
"${ROOT}/appliance/assemble_initramfs.sh"

{
    echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "os=$(. /etc/os-release && echo "${PRETTY_NAME}")"
    echo "uname=$(uname -r)"
    echo "criu=$(/usr/sbin/criu --version | head -n1)"
    echo "initramfs=$(ls -lh "${ROOT}/appliance/initramfs.cpio.gz" | awk '{print $5}')"
    echo "debs=$(find "${DEB_DIR}" -name '*.deb' | wc -l)"
} | tee "${BIN_DIR}/vendor-stamp.txt"

echo "=== Vendor complete ==="
ls -lh "${BIN_DIR}/criu" "${ROOT}/scripts/daemonize" "${ROOT}/appliance/initramfs.cpio.gz"
du -sh "${DEB_DIR}"
