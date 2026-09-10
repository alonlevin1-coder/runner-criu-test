#!/usr/bin/env bash
# Freeze a process tree, snapshot open regular files, later unfreeze.
# Used before criu dump --leave-running so 9p-visible files cannot drift
# while QEMU boots and criu restore validates sizes (R19 _diag log mismatch).
set -euo pipefail

declare -A FREEZE_EXCLUDE=()

collect_tree_pids_raw() {
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

collect_tree_pids() {
    local root="${1:?root pid}"
    local exclude_file="${2:-}"
    load_freeze_excludes "${exclude_file}"
    collect_tree_pids_respecting_excludes "${root}"
}

load_freeze_excludes() {
    local exclude_file="${1:-}"
    local pid

    FREEZE_EXCLUDE=()
    [ -n "${exclude_file}" ] && [ -f "${exclude_file}" ] || return 0
    while read -r pid; do
        [ -n "${pid}" ] || continue
        [[ "${pid}" =~ ^[0-9]+$ ]] || continue
        FREEZE_EXCLUDE["${pid}"]=1
        while read -r desc; do
            [ -n "${desc}" ] || continue
            FREEZE_EXCLUDE["${desc}"]=1
        done < <(collect_tree_pids_raw "${pid}")
    done < "${exclude_file}"
}

collect_tree_pids_respecting_excludes() {
    local root="${1:?root pid}"
    local -a queue=("${root}")
    local pid child

    while [ "${#queue[@]}" -gt 0 ]; do
        pid="${queue[0]}"
        queue=("${queue[@]:1}")
        if [ -n "${FREEZE_EXCLUDE[${pid}]+x}" ]; then
            continue
        fi
        printf '%s\n' "${pid}"
        while read -r child; do
            [ -n "${child}" ] || continue
            queue+=("${child}")
        done < <(pgrep -P "${pid}" 2>/dev/null || true)
    done
}

freeze_tree() {
    local checkpoint_dir="${1:?checkpoint dir}"
    local root_pid="${2:?root pid}"
    local pidfile="${checkpoint_dir}/sigstopped_pids.txt"
    local exclude_file="${checkpoint_dir}/freeze_exclude_pids.txt"

    : > "${pidfile}"
    while read -r pid; do
        [ -n "${pid}" ] || continue
        kill -STOP "${pid}" 2>/dev/null || sudo kill -STOP "${pid}" 2>/dev/null || true
        echo "${pid}" >> "${pidfile}"
    done < <(collect_tree_pids "${root_pid}" "${exclude_file}")

    echo "host_tree_frozen=yes" >> "${checkpoint_dir}/state.txt"
    echo "frozen_pid_count=$(wc -l < "${pidfile}" | tr -d ' ')" >> "${checkpoint_dir}/state.txt"
    if [ -f "${exclude_file}" ]; then
        echo "freeze_exclude_file=yes" >> "${checkpoint_dir}/state.txt"
        tr '\n' ',' < "${exclude_file}" | sed 's/,$/\n/' \
            >> "${checkpoint_dir}/state.txt" 2>/dev/null || true
    fi
}

# Step shell stays running during migration; pause only for criu dump consistency.
orchestrator_pause_for_dump() {
    local checkpoint_dir="${1:?checkpoint dir}"
    local exclude_file="${checkpoint_dir}/freeze_exclude_pids.txt"
    local paused="${checkpoint_dir}/orchestrator_dump_paused.txt"
    local pid

    : > "${paused}"
    [ -f "${exclude_file}" ] || return 0
    while read -r pid; do
        [ -n "${pid}" ] || continue
        [[ "${pid}" =~ ^[0-9]+$ ]] || continue
        kill -STOP "${pid}" 2>/dev/null || sudo kill -STOP "${pid}" 2>/dev/null || true
        echo "${pid}" >> "${paused}"
    done < "${exclude_file}"
}

orchestrator_resume_after_dump() {
    local checkpoint_dir="${1:?checkpoint dir}"
    local paused="${checkpoint_dir}/orchestrator_dump_paused.txt"
    local pid

    [ -f "${paused}" ] || return 0
    while read -r pid; do
        [ -n "${pid}" ] || continue
        kill -CONT "${pid}" 2>/dev/null || sudo kill -CONT "${pid}" 2>/dev/null || true
    done < "${paused}"
    echo "orchestrator_dump_resumed=yes" >> "${checkpoint_dir}/state.txt"
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

kill_tree() {
    local checkpoint_dir="${1:?checkpoint dir}"
    local pidfile="${checkpoint_dir}/sigstopped_pids.txt"

    [ -f "${pidfile}" ] || return 0
    while read -r pid; do
        [ -n "${pid}" ] || continue
        kill -9 "${pid}" 2>/dev/null || sudo kill -9 "${pid}" 2>/dev/null || true
    done < "${pidfile}"
    echo "host_tree_killed=yes" >> "${checkpoint_dir}/state.txt"
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

    local raw_addr sport close_sec
    close_sec="${TCP_CLOSE_TIMEOUT_SEC:-15}"

    : > "${log}"
    while read -r pid; do
        [ -n "${pid}" ] || continue
        while read -r line; do
            [ -n "${line}" ] || continue
            raw_addr="$(awk '{print $4}' <<< "${line}")"
            sport=""
            if [[ "${raw_addr}" =~ ^\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|[0-9a-fA-F:]+)\]:([0-9]+)$ ]]; then
                sport="${BASH_REMATCH[2]}"
            elif [[ "${raw_addr}" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$ ]]; then
                sport="${BASH_REMATCH[2]}"
            else
                sport="$(sed 's/.*://' <<< "${raw_addr}")"
            fi
            [ -n "${sport}" ] || continue
            echo "closing pid=${pid} sport=:${sport} ${line}" >> "${log}"
            if timeout "${close_sec}" sudo ss -t -H -K "sport = :${sport}" >> "${log}" 2>&1; then
                closed=$((closed + 1))
            else
                echo "WARN: ss -K timed out or failed for sport=:${sport}" >> "${log}"
            fi
        done < <(timeout 30 sudo ss -H -antp 2>/dev/null | grep -F "pid=${pid}," || true)
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
    done < <(collect_tree_pids "${root_pid}" "${checkpoint_dir}/freeze_exclude_pids.txt")

    echo "frozen_file_count=$(( $(wc -l < "${manifest}") - 1 ))" >> "${checkpoint_dir}/state.txt"
}
