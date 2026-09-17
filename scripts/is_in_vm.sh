#!/usr/bin/env bash
# Guest detection from procfs — not /tmp, /run, or /etc (systemd and the
# /etc overlay replace those). Source this file; do not execute it.
#
# QEMU appends t9_is_vm=1. That token is never on the GitHub-hosted Azure
# host cmdline. After CRIU restore, /proc is the guest kernel, so this flips.
#
# Hostname is a backup only: restored tasks keep the dumped host UTS ns
# unless something nsenter's them, so hostname often still looks like the host.

is_in_vm() {
    grep -qw 't9_is_vm=1' /proc/cmdline 2>/dev/null && return 0

    local now hostid
    now="$(tr -d '[:space:]' < /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
    if [ -n "${now}" ]; then
        for hostid in \
            "${CP:-}/host_boot_id" \
            "${RUNNER_VM_CHECKPOINT:-}/host_boot_id" \
            /mnt/checkpoint/host_boot_id \
            /run/runner_checkpoint/host_boot_id
        do
            [ -f "${hostid}" ] || continue
            [ "${now}" != "$(tr -d '[:space:]' < "${hostid}")" ] && return 0
        done
    fi

    [ "$(hostname 2>/dev/null)" = "qemu-restore-vm" ] && return 0
    return 1
}
