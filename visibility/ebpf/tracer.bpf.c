#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_endian.h>

enum config_index {
    CFG_REDIRECT_ENABLED = 0,
    CFG_PROXY_IP = 1,
    CFG_PROXY_PORT = 2,
    CFG_BYPASS_UID = 3,
};

struct conn_key_t {
    u32 src_ip;
    u16 src_port;
    u32 dst_ip;
    u16 dst_port;
};

struct conn_val_t {
    u64 open_ts;
    u32 pid;
    u32 tgid;
    u32 uid;
    u32 gid;
    char comm[16];
};

struct conn_event_t {
    u32 event_type;
    u32 src_ip;
    u16 src_port;
    u32 orig_dst_ip;
    u16 orig_dst_port;
    u32 redirect_dst_ip;
    u16 redirect_dst_port;
    u32 pid;
    u64 start_time;
    u32 tgid;
    u32 uid;
    u32 gid;
    u64 timestamp_ns;
    u32 redirected;
    char comm[16];
} __attribute__((packed));

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 4);
    __type(key, u32);
    __type(value, u32);
} config_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10240);
    __type(key, struct conn_key_t);
    __type(value, struct conn_val_t);
} active_connections SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10240);
    __type(key, u64);
    __type(value, struct conn_event_t);
} sock_info SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERF_EVENT_ARRAY);
    __uint(key_size, sizeof(u32));
    __uint(value_size, sizeof(u32));
} events SEC(".maps");

SEC("cgroup/connect4")
int trace_connect4(struct bpf_sock_addr *ctx)
{
    if (ctx->family != 2) /* AF_INET */
        return 1;

    u64 uid_gid = bpf_get_current_uid_gid();
    u32 uid = (u32)(uid_gid & 0xFFFFFFFF);
    u32 gid = (u32)(uid_gid >> 32);

    u32 cfg_idx = CFG_BYPASS_UID;
    u32 *bypass_uid = bpf_map_lookup_elem(&config_map, &cfg_idx);
    if (bypass_uid && *bypass_uid != 0 && uid == *bypass_uid)
        return 1;

    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 tgid = (u32)(pid_tgid >> 32);

    struct conn_event_t evt = {};
    evt.event_type = 1;
    evt.pid = tgid;
    evt.tgid = tgid;
    evt.uid = uid;
    evt.gid = gid;

    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    evt.start_time = BPF_CORE_READ(task, group_leader, start_time);
    evt.timestamp_ns = bpf_ktime_get_ns();
    bpf_get_current_comm(&evt.comm, sizeof(evt.comm));

    evt.orig_dst_ip = ctx->user_ip4;
    evt.orig_dst_port = ctx->user_port;
    evt.redirect_dst_ip = ctx->user_ip4;
    evt.redirect_dst_port = ctx->user_port;

    cfg_idx = CFG_REDIRECT_ENABLED;
    u32 *redirect_enabled = bpf_map_lookup_elem(&config_map, &cfg_idx);
    if (redirect_enabled && *redirect_enabled == 1) {
        cfg_idx = CFG_PROXY_IP;
        u32 *proxy_ip = bpf_map_lookup_elem(&config_map, &cfg_idx);
        cfg_idx = CFG_PROXY_PORT;
        u32 *proxy_port = bpf_map_lookup_elem(&config_map, &cfg_idx);
        if (proxy_ip && proxy_port && *proxy_ip != 0 && *proxy_port != 0) {
            evt.redirect_dst_ip = *proxy_ip;
            evt.redirect_dst_port = *proxy_port;
            evt.redirected = 1;
            ctx->user_ip4 = *proxy_ip;
            ctx->user_port = *proxy_port;
        }
    }

    u64 cookie = bpf_get_socket_cookie(ctx);
    bpf_map_update_elem(&sock_info, &cookie, &evt, BPF_ANY);
    return 1;
}

SEC("sockops")
int trace_sock_ops(struct bpf_sock_ops *skops)
{
    u32 op = skops->op;

    if (op == BPF_SOCK_OPS_ACTIVE_ESTABLISHED_CB) {
        u64 cookie = bpf_get_socket_cookie(skops);
        struct conn_event_t *evt = bpf_map_lookup_elem(&sock_info, &cookie);
        if (evt) {
            evt->src_ip = skops->local_ip4;
            evt->src_port = bpf_htons((u16)skops->local_port);
            evt->timestamp_ns = bpf_ktime_get_ns();
            bpf_perf_event_output(skops, &events, BPF_F_CURRENT_CPU, evt, sizeof(*evt));
            bpf_map_delete_elem(&sock_info, &cookie);
        }
    } else if (op == BPF_SOCK_OPS_STATE_CB) {
        int new_state = skops->args[1];
        if (new_state == BPF_TCP_CLOSE) {
            u64 cookie = bpf_get_socket_cookie(skops);
            bpf_map_delete_elem(&sock_info, &cookie);

            u64 pid_tgid = bpf_get_current_pid_tgid();
            u64 uid_gid = bpf_get_current_uid_gid();

            struct conn_event_t evt = {};
            evt.event_type = 2;
            evt.src_ip = skops->local_ip4;
            evt.src_port = bpf_htons((u16)skops->local_port);
            evt.orig_dst_ip = skops->remote_ip4;
            evt.orig_dst_port = skops->remote_port;
            evt.pid = (u32)(pid_tgid >> 32);
            evt.tgid = (u32)(pid_tgid >> 32);
            evt.uid = (u32)(uid_gid & 0xFFFFFFFF);
            evt.gid = (u32)(uid_gid >> 32);

            struct task_struct *task = (struct task_struct *)bpf_get_current_task();
            evt.start_time = BPF_CORE_READ(task, group_leader, start_time);
            evt.timestamp_ns = bpf_ktime_get_ns();
            bpf_get_current_comm(&evt.comm, sizeof(evt.comm));
            bpf_perf_event_output(skops, &events, BPF_F_CURRENT_CPU, &evt, sizeof(evt));
        }
    }
    return 1;
}

char LICENSE[] SEC("license") = "GPL";
