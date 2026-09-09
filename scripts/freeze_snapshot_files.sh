#!/usr/bin/env bash
# Freeze a process tree, snapshot open regular files, later unfreeze.
# Used before criu dump --leave-running so 9p-visible files cannot drift
# while QEMU boots and criu restore validates sizes (R19 _diag log mismatch).
set -euo pipefail

collect_tree_pids() {
    local root="${1:?root pid}"
    local -a queue=("${root}")
    local -a seen=()
    local pid child

    while [ "${#queue[@]}" -gt 0 ]; do
        pid="${queue[0]}"
        queue=("${queue[@]:1}")
        seen+=("${pid}")
        while read -r child; do
            [ -n "${child}" ] || continue
            queue+=("${child}")
        done < <(pgrep -P "${pid}" 2>/dev/null || true)
    done
    printf '%s\n' "${seen[@]}"
}

freeze_tree() {
    local checkpoint_dir="${1:?checkpoint dir}"
    local root_pid="${2:?root pid}"
    local pidfile="${checkpoint_dir}/sigstopped_pids.txt"

    : > "${pidfile}"
    while read -r pid; do
        [ -n "${pid}" ] || continue
        kill -STOP "${pid}" 2>/dev/null || sudo kill -STOP "${pid}" 2>/dev/null || true
        echo "${pid}" >> "${pidfile}"
    done < <(collect_tree_pids "${root_pid}")

    echo "host_tree_frozen=yes" >> "${checkpoint_dir}/state.txt"
    echo "frozen_pid_count=$(wc -l < "${pidfile}" | tr -d ' ')" >> "${checkpoint_dir}/state.txt"
}

unfreeze_tree() {
    local checkpoint_dir="${1:?checkpoint dir}"
    local pidfile="${checkpoint_dir}/sigstopped_pids.txt"

    [ -f "${pidfile}" ] || return 0
    while read -r pid; do
        [ -n "${pid}" ] || continue
        kill -CONT "${pid}" 2>/dev/null || sudo kill -CONT "${pid}" 2>/dev/null || true
    done < "${pidfile}"
    echo "host_tree_unfrozen=yes" >> "${checkpoint_dir}/state.txt"
}

# After a --tcp-established dump the checkpoint image owns the live socket
# state. Kill host-side TCP sockets while the tree is still SIGSTOP'd so the
# restored VM copy does not race the host Worker on the same connections.
close_tree_tcp_sockets() {
    local checkpoint_dir="${1:?checkpoint dir}"
    local pidfile="${checkpoint_dir}/sigstopped_pids.txt"
    local log="${checkpoint_dir}/host_tcp_close.log"
    local closed=0
    local pid line sport

    [ -f "${pidfile}" ] || return 0
    if ! command -v ss >/dev/null 2>&1; then
        echo "host_tcp_sockets_closed=skipped reason=no_ss" >> "${checkpoint_dir}/state.txt"
        return 0
    fi

    : > "${log}"
    while read -r pid; do
        [ -n "${pid}" ] || continue
        while read -r line; do
            [ -n "${line}" ] || continue
            sport="$(echo "${line}" | awk '{print $4}' | sed 's/.*://')"
            [ -n "${sport}" ] || continue
            echo "closing pid=${pid} sport=:${sport} ${line}" >> "${log}"
            if sudo ss -H -K "sport = :${sport}" >> "${log}" 2>&1; then
                closed=$((closed + 1))
            fi
        done < <(sudo ss -H -antp 2>/dev/null | grep -F "pid=${pid}," || true)
    done < "${pidfile}"

    echo "host_tcp_sockets_closed=yes count=${closed}" >> "${checkpoint_dir}/state.txt"
}

snapshot_open_files() {
    local checkpoint_dir="${1:?checkpoint dir}"
    local root_pid="${2:?root pid}"
    local frozen_root="${checkpoint_dir}/frozen_files"
    local manifest="${frozen_root}/manifest.tsv"
    local -A seen=()

    rm -rf "${frozen_root}"
    mkdir -p "${frozen_root}"
    printf 'rel_path\tsize_bytes\tmode\n' > "${manifest}"

    while read -r pid; do
        [ -n "${pid}" ] || continue
        [ -d "/proc/${pid}/fd" ] || continue
        local fd target abspath relpath dest size mode
        for fd in /proc/"${pid}"/fd/*; do
            [ -e "${fd}" ] || continue
            target="$(readlink "${fd}" 2>/dev/null || true)"
            [ -n "${target}" ] || continue
            case "${target}" in
                pipe:*|socket:*|anon_inode:*|/dev/*|/proc/*|/sys/*) continue ;;
            esac
            abspath="$(readlink -f "${target}" 2>/dev/null || true)"
            [ -n "${abspath}" ] || continue
            [ -f "${abspath}" ] || continue
            case "${abspath}" in
                /dev/*|/proc/*|/sys/*) continue ;;
            esac
            relpath="${abspath#/}"
            [ -n "${seen[${relpath}]+x}" ] && continue
            seen["${relpath}"]=1
            dest="${frozen_root}/${relpath}"
            mkdir -p "$(dirname "${dest}")"
            cp -a --preserve=mode,timestamps "${abspath}" "${dest}" 2>/dev/null \
                || cp "${abspath}" "${dest}"
            size="$(stat -c '%s' "${dest}")"
            mode="$(stat -c '%a' "${dest}")"
            printf '%s\t%s\t%s\n' "${relpath}" "${size}" "${mode}" >> "${manifest}"
        done
    done < <(collect_tree_pids "${root_pid}")

    echo "frozen_file_count=$(( $(wc -l < "${manifest}") - 1 ))" >> "${checkpoint_dir}/state.txt"
}
