#!/usr/bin/env bash
set -euo pipefail

# Build CRIU from source on the GitHub-hosted runner.
#
# Ubuntu's criu package still uses a 4KB XSAVE buffer. Azure SKUs with AMX
# (Sapphire Rapids and newer) have an ~11KB NT_X86_XSTATE frame. PTRACE_GETREGSET
# silently truncates; PTRACE_SETREGSET then fails with EFAULT ("Can't set FPU
# registers: Bad address") while infecting .NET ThreadPool threads.

CRIU_TAG="${CRIU_TAG:-v4.2.1}"
BUILD_DIR="${CRIU_BUILD_DIR:-/tmp/criu-build}"

echo "=== Building CRIU ${CRIU_TAG} from source ==="

# Listener was started before this job. Replacing libc/libssl turns those
# mappings into CRIU ghost files and dump fails at the default 1MB cap.
sudo apt-mark hold libc6 libc6-dev libssl3 libssl-dev 2>/dev/null || true

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-upgrade \
    -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    build-essential pkg-config \
    libprotobuf-dev libprotobuf-c-dev protobuf-c-compiler \
    libcap-dev libnl-3-dev libnet-dev \
    python3-protobuf protobuf-compiler \
    libnl-route-3-dev libbsd-dev libnftables-dev \
    libgnutls28-dev uuid-dev

rm -rf "${BUILD_DIR}"
git clone --depth 1 --branch "${CRIU_TAG}" https://github.com/checkpoint-restore/criu.git "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Enlarge the compiled XSAVE buffer past AMX (11KB) and leave headroom.
FPU_HDR="compel/arch/x86/src/lib/include/uapi/asm/fpu.h"
if [ -f "${FPU_HDR}" ]; then
    sed -i 's/#define XSAVE_SIZE[[:space:]]*4\*4096/#define XSAVE_SIZE  8*4096/' "${FPU_HDR}"
    grep -n "XSAVE_SIZE" "${FPU_HDR}" | head
fi

python3 - << 'PY'
from pathlib import Path

p = Path("compel/arch/x86/src/lib/infect.c")
text = p.read_text()
if "#include <string.h>" not in text:
    text = text.replace("#include <errno.h>\n", "#include <errno.h>\n#include <string.h>\n")
old = """int compel_set_task_ext_regs(pid_t pid, user_fpregs_struct_t *ext_regs)
{
	struct iovec iov;

	pr_info("Restoring GP/FPU registers for %d\\n", pid);

	if (!compel_cpu_has_feature(X86_FEATURE_OSXSAVE)) {
		if (ptrace(PTRACE_SETFPREGS, pid, NULL, ext_regs)) {
			pr_perror("Can't set FPU registers for %d", pid);
			return -1;
		}
		return 0;
	}

	iov.iov_base = ext_regs;
	iov.iov_len = sizeof(*ext_regs);

	if (ptrace(PTRACE_SETREGSET, pid, (unsigned int)NT_X86_XSTATE, &iov) < 0) {
		pr_perror("Can't set FPU registers for %d", pid);
		return -1;
	}

	return 0;
}
"""
new = """int compel_set_task_ext_regs(pid_t pid, user_fpregs_struct_t *ext_regs)
{
	struct iovec iov;
	size_t xstate_len = sizeof(*ext_regs);

	pr_info("Restoring GP/FPU registers for %d\\n", pid);

	if (!compel_cpu_has_feature(X86_FEATURE_OSXSAVE)) {
		if (ptrace(PTRACE_SETFPREGS, pid, NULL, ext_regs)) {
			pr_perror("Can't set FPU registers for %d", pid);
			return -1;
		}
		return 0;
	}

	/*
	 * Probe the kernel's NT_X86_XSTATE size. SETREGSET returns EFAULT when
	 * iov_len is smaller than fpu_user_xstate_size (AMX/APX hosts). Using
	 * the GETREGSET-reported length avoids both undersized and some
	 * oversize-buffer failures.
	 */
	{
		user_fpregs_struct_t probe;
		memset(&probe, 0, sizeof(probe));
		iov.iov_base = &probe;
		iov.iov_len = sizeof(probe);
		if (ptrace(PTRACE_GETREGSET, pid, (unsigned int)NT_X86_XSTATE, &iov) == 0 && iov.iov_len > 0)
			xstate_len = iov.iov_len;
	}

	if (xstate_len > sizeof(*ext_regs)) {
		pr_err("Kernel xstate size %zu exceeds compiled buffer %zu\\n",
		       xstate_len, sizeof(*ext_regs));
		return -1;
	}

	pr_info("Setting xstate for %d with iov_len=%zu (buf=%zu)\\n",
		pid, xstate_len, sizeof(*ext_regs));

	iov.iov_base = ext_regs;
	iov.iov_len = xstate_len;

	if (ptrace(PTRACE_SETREGSET, pid, (unsigned int)NT_X86_XSTATE, &iov) < 0) {
		pr_perror("Can't set FPU registers for %d (xstate_len=%zu)", pid, xstate_len);
		return -1;
	}

	return 0;
}
"""
if old not in text:
    raise SystemExit("compel_set_task_ext_regs pattern not found; CRIU source changed")
p.write_text(text.replace(old, new, 1))
print("Patched compel_set_task_ext_regs to probe NT_X86_XSTATE size")
PY

make -j"$(nproc)" criu
test -x criu/criu
sudo install -m 755 criu/criu /usr/sbin/criu
sudo install -m 755 criu/criu /usr/local/sbin/criu
hash -r

cat > /tmp/xsave_size.c << 'EOF'
#include <stdio.h>
int main(void) {
	unsigned a = 0, b = 0, c = 0, d = 0;
	__asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(0x0d), "c"(0));
	printf("CPUID.0DH.0: xsave_size(ebx)=%u xsave_size_max(ecx)=%u xcr0_lo(eax)=0x%x xcr0_hi(edx)=0x%x\n",
	       b, c, a, d);
	return 0;
}
EOF
gcc -o /tmp/xsave_size /tmp/xsave_size.c
chmod 755 /tmp/xsave_size
/tmp/xsave_size

echo "--- Installed CRIU ---"
command -v criu
criu --version
ls -l /usr/sbin/criu
echo "=== CRIU build complete ==="
