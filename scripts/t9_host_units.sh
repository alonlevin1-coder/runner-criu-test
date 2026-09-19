#!/usr/bin/env bash
# Snapshot host systemd units, start the same set in the guest, or compare.
# Skip Azure/cloud agents, TAP-conflicting network managers, host sshd (Dropbear),
# apt timers, udev-settle, and the GitHub runner itself.
set -u

usage() {
    echo "usage: $0 snapshot <out> | start [list] | compare [host-list]" >&2
    exit 2
}

unit_skip() {
    local u="$1"
    case "${u}" in
        walinuxagent.service|waagent.service|azure*|hv-*|hyper-v*|hyperv*)
            return 0 ;;
        cloud-init*|cloud-config*|cloud-final*)
            return 0 ;;
        systemd-networkd.service|systemd-networkd.socket|systemd-networkd-wait-online.service)
            return 0 ;;
        NetworkManager.service|NetworkManager-wait-online.service|NetworkManager.socket)
            return 0 ;;
        systemd-udev-settle.service)
            return 0 ;;
        unattended-upgrades.service|apt-daily.service|apt-daily.timer|apt-daily-upgrade.service|apt-daily-upgrade.timer)
            return 0 ;;
        ssh.service|ssh.socket|sshd.service|sshd.socket)
            return 0 ;;
        apparmor.service|snapd.apparmor.service)
            return 0 ;;
        hosted-compute-agent.service|actions.runner*|gha-*|runner-provisioner*)
            return 0 ;;
        multipathd.service|multipathd.socket)
            return 0 ;;
        getty@*|serial-getty@*|console-getty.service|autovt@*|plymouth*)
            return 0 ;;
        user@*|user-runtime-dir@*|session-*.scope)
            return 0 ;;
        systemd-ask-password*|emergency.service|rescue.service)
            return 0 ;;
        systemd-fsck*|systemd-remount-fs.service|systemd-update-utmp*|systemd-machine-id-commit.service)
            return 0 ;;
        kmod-static-nodes.service|ldconfig.service|systemd-hwdb-update.service)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

guest_covers() {
    local u="$1" guest_list="$2"
    systemctl is-active --quiet "${u}" 2>/dev/null && return 0
    grep -qxF "${u}" "${guest_list}" && return 0
    case "${u}" in
        syslog.socket)
            grep -qxF systemd-journald-dev-log.socket "${guest_list}" && return 0
            systemctl is-active --quiet rsyslog.service 2>/dev/null && return 0
            ;;
    esac
    return 1
}

prep_unit() {
    case "$1" in
        chrony.service)
            mkdir -p /var/lib/chrony /var/log/chrony /run/chrony /etc/chrony
            chmod 750 /run/chrony 2>/dev/null || true
            if [ ! -s /etc/chrony/chrony.conf ]; then
                cat > /etc/chrony/chrony.conf << 'EOF'
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
leapsectz right/UTC
logdir /var/log/chrony
EOF
            fi
            # Host Azure PHC is not in QEMU; keep NTP but drop Hyper-V PTP.
            sed -i -E '/refclock[[:space:]]+PHC/d;/ptp_hyperv/d' /etc/chrony/chrony.conf \
                /etc/chrony/conf.d/* /etc/chrony/sources.d/* /etc/default/chrony 2>/dev/null || true
            mkdir -p /etc/systemd/system/chrony.service.d
            cat > /etc/systemd/system/chrony.service.d/t9-guest.conf << 'EOF'
[Service]
ProtectClock=no
PrivateDevices=no
RestrictRealtime=no
EOF
            if getent passwd _chrony >/dev/null 2>&1; then
                chown -R _chrony:_chrony /var/lib/chrony /var/log/chrony /run/chrony /etc/chrony 2>/dev/null || true
            fi
            systemctl daemon-reload >/dev/null 2>&1 || true
            ;;
        mono-xsp4.service)
            mkdir -p /var/run /run /etc/xsp4
            ;;
        php8.1-fpm.service|php*-fpm.service)
            mkdir -p /run/php /var/log
            ;;
        rsyslog.service|syslog.socket)
            mkdir -p /var/log /run/systemd/journal
            touch /var/log/syslog 2>/dev/null || true
            ;;
    esac
}

dump_running() {
    systemctl list-units --type=service --state=running --no-legend --plain --no-pager 2>/dev/null \
        | awk '{print $1}'
    systemctl list-units --type=socket --state=running --no-legend --plain --no-pager 2>/dev/null \
        | awk '{print $1}'
}

normalize_list() {
    awk 'NF && $1 !~ /^#/ {print $1}' | sort -u
}

cmd="${1:-}"
case "${cmd}" in
    snapshot)
        out="${2:-}"
        [ -n "${out}" ] || usage
        {
            echo "# t9 host running units $(date -u +%Y-%m-%dT%H:%M:%SZ) kernel=$(uname -r) host=$(hostname)"
            dump_running | normalize_list
        } > "${out}"
        chmod a+r "${out}" 2>/dev/null || true
        echo "t9_host_units: wrote $(grep -cE '^[a-zA-Z0-9]' "${out}" || true) units to ${out}"
        ;;
    start)
        list="${2:-/mnt/checkpoint/host_running_units.txt}"
        [ -f "${list}" ] || list=/etc/t9-host-units.txt
        if [ ! -f "${list}" ]; then
            echo "t9_host_units: no host unit list at ${list}" >&2
            exit 1
        fi
        log="${3:-/mnt/checkpoint/guest_host_units.log}"
        mkdir -p "$(dirname "${log}")" 2>/dev/null || true
        : > "${log}"
        started=0
        skipped=0
        failed=0
        systemctl daemon-reload >/dev/null 2>&1 || true
        while IFS= read -r unit; do
            [ -n "${unit}" ] || continue
            if unit_skip "${unit}"; then
                echo "skip ${unit}" | tee -a "${log}"
                skipped=$((skipped + 1))
                continue
            fi
            prep_unit "${unit}"
            systemctl unmask "${unit}" >/dev/null 2>&1 || true
            systemctl reset-failed "${unit}" >/dev/null 2>&1 || true
            if timeout 20 systemctl start "${unit}" >>"${log}" 2>&1; then
                echo "start ok ${unit}" | tee -a "${log}"
                started=$((started + 1))
            else
                echo "start FAIL ${unit} active=$(systemctl is-active "${unit}" 2>/dev/null || true)" | tee -a "${log}"
                systemctl status "${unit}" --no-pager -l >>"${log}" 2>&1 || true
                journalctl -u "${unit}" -n 25 --no-pager >>"${log}" 2>&1 || true
                failed=$((failed + 1))
            fi
        done < <(normalize_list < "${list}")
        echo "t9_host_units: started=${started} skipped=${skipped} failed=${failed}" | tee -a "${log}"
        dump_running | normalize_list > /mnt/checkpoint/guest_running_units.txt 2>/dev/null \
            || dump_running | normalize_list > /tmp/guest_running_units.txt
        ;;
    compare)
        host_list="${2:-/mnt/checkpoint/host_running_units.txt}"
        [ -f "${host_list}" ] || host_list=/etc/t9-host-units.txt
        guest_list="$(mktemp)"
        dump_running | normalize_list > "${guest_list}"
        echo "=== host running units (raw) ==="
        cat "${host_list}"
        echo "=== guest running units ==="
        cat "${guest_list}"
        miss="$(mktemp)"
        : > "${miss}"
        while IFS= read -r unit; do
            [ -n "${unit}" ] || continue
            unit_skip "${unit}" && continue
            if ! guest_covers "${unit}" "${guest_list}"; then
                echo "${unit}" >> "${miss}"
            fi
        done < <(normalize_list < "${host_list}")
        extra="$(mktemp)"
        comm -13 <(normalize_list < "${host_list}") "${guest_list}" > "${extra}" || true
        echo "=== missing on guest (expected from host, not skipped) ==="
        if [ -s "${miss}" ]; then
            cat "${miss}"
        else
            echo "(none)"
        fi
        echo "=== extra on guest (not on host dump) ==="
        cat "${extra}"
        if [ -s "${miss}" ]; then
            echo "FAIL: guest missing host daemons"
            rm -f "${guest_list}" "${miss}" "${extra}"
            exit 1
        fi
        echo "CONFIRMED: guest has host daemons (azure/cloud/ssh/networkd skipped)"
        rm -f "${guest_list}" "${miss}" "${extra}"
        ;;
    *)
        usage ;;
esac
