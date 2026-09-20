#include <uapi/linux/ptrace.h>
#include <linux/socket.h>
#include <uapi/linux/bpf.h>
#include <bcc/proto.h>

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned long long u64;
// Config indices stored in config_map
enum config_index {
    CFG_REDIRECT_ENABLED = 0,
    CFG_PROXY_IP         = 1, // IPv4 network byte order (or host byte order as agreed)
    CFG_PROXY_PORT       = 2, // Port in network byte order
    CFG_BYPASS_UID       = 3, // UID of local proxy to bypass interception loop
};

// Configuration array map: index -> u32 value
BPF_ARRAY(config_map, u32, 4);

// Active connection key: 4-tuple
struct conn_key_t {
    u32 src_ip;
    u16 src_port;
    u32 dst_ip;
    u16 dst_port;
};

// Active connection value
struct conn_val_t {
    u64 open_ts;
    u32 pid;
    u32 tgid;
    u32 uid;
    u32 gid;
    char comm[16];
};

// Event payload pushed to userspace via perf buffer
struct conn_event_t {
    u32 event_type;        // 1 = OPEN, 2 = CLOSE
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
};

// Hash map to track active connections across OPEN/CLOSE
BPF_HASH(active_connections, struct conn_key_t, struct conn_val_t, 10240);

// Hash map to store in-flight connection metadata between connect4 and sock_ops established
BPF_HASH(sock_info, u64, struct conn_event_t, 10240);

// Perf output ring buffer for streaming events to userspace
BPF_PERF_OUTPUT(events);

/**
 * cgroup/connect4 Hook: Intercept IPv4 connect() calls
 */
int trace_connect4(struct bpf_sock_addr *ctx) {
    if (ctx->family != AF_INET) {
        return 1;
    }

    u64 uid_gid = bpf_get_current_uid_gid();
    u32 uid = (u32)(uid_gid & 0xFFFFFFFF);
    u32 gid = (u32)(uid_gid >> 32);

    // Check if current user is the bypass UID (e.g. proxy user)
    u32 cfg_idx = CFG_BYPASS_UID;
    u32 *bypass_uid = config_map.lookup(&cfg_idx);
    if (bypass_uid && *bypass_uid != 0 && uid == *bypass_uid) {
        return 1; // Bypass proxy traffic to avoid infinite loop
    }

    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 pid = (u32)(pid_tgid & 0xFFFFFFFF);
    u32 tgid = (u32)(pid_tgid >> 32);

    struct conn_event_t evt = {};
    evt.event_type = 1; // OPEN
    evt.pid = tgid;
    evt.tgid = tgid;
    evt.uid = uid;
    evt.gid = gid;
    
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    struct task_struct *group_leader;
    bpf_probe_read_kernel(&group_leader, sizeof(group_leader), &task->group_leader);
    bpf_probe_read_kernel(&evt.start_time, sizeof(evt.start_time), &group_leader->start_time);
    
    evt.timestamp_ns = bpf_ktime_get_ns();
    bpf_get_current_comm(&evt.comm, sizeof(evt.comm));

    evt.src_ip = 0; // Local source IP/port not assigned until after socket bind
    evt.src_port = 0;
    evt.orig_dst_ip = ctx->user_ip4;
    evt.orig_dst_port = ctx->user_port;
    evt.redirect_dst_ip = ctx->user_ip4;
    evt.redirect_dst_port = ctx->user_port;
    evt.redirected = 0;

    // Check if redirection is enabled
    cfg_idx = CFG_REDIRECT_ENABLED;
    u32 *redirect_enabled = config_map.lookup(&cfg_idx);
    if (redirect_enabled && *redirect_enabled == 1) {
        cfg_idx = CFG_PROXY_IP;
        u32 *proxy_ip = config_map.lookup(&cfg_idx);
        cfg_idx = CFG_PROXY_PORT;
        u32 *proxy_port = config_map.lookup(&cfg_idx);

        if (proxy_ip && proxy_port && *proxy_ip != 0 && *proxy_port != 0) {
            evt.redirect_dst_ip = *proxy_ip;
            evt.redirect_dst_port = *proxy_port;
            evt.redirected = 1;

            // Transparent redirection: rewrite socket destination
            ctx->user_ip4 = *proxy_ip;
            ctx->user_port = *proxy_port;
        }
    }

    // Save connection event in sock_info keyed by socket cookie for retrieval upon ESTABLISHED
    u64 cookie = bpf_get_socket_cookie(ctx);
    sock_info.update(&cookie, &evt);
    return 1;
}

/**
 * sock_ops Hook: Intercept TCP state changes (ACTIVE_ESTABLISHED and TCP_CLOSE)
 */
int trace_sock_ops(struct bpf_sock_ops *skops) {
    u32 op = skops->op;

    if (op == BPF_SOCK_OPS_ACTIVE_ESTABLISHED_CB) {
        u64 cookie = bpf_get_socket_cookie(skops);
        struct conn_event_t *evt = sock_info.lookup(&cookie);
        if (evt) {
            evt->src_ip = skops->local_ip4;
            evt->src_port = bpf_htons((u16)skops->local_port);
            evt->timestamp_ns = bpf_ktime_get_ns();

            // Submit OPEN event with assigned ephemeral source port to userspace
            events.perf_submit(skops, evt, sizeof(*evt));
            sock_info.delete(&cookie);
        }
    } else if (op == BPF_SOCK_OPS_STATE_CB) {
        int old_state = skops->args[0];
        int new_state = skops->args[1];

        // Only handle transition to CLOSE state
        if (new_state == BPF_TCP_CLOSE) {
            u64 cookie = bpf_get_socket_cookie(skops);
            sock_info.delete(&cookie);

            u64 pid_tgid = bpf_get_current_pid_tgid();
            u64 uid_gid = bpf_get_current_uid_gid();

            struct conn_event_t evt = {};
            evt.event_type = 2; // CLOSE
            evt.src_ip = skops->local_ip4;
            evt.src_port = bpf_htons((u16)skops->local_port);
            evt.orig_dst_ip = skops->remote_ip4;
            evt.orig_dst_port = skops->remote_port;
            evt.pid = (u32)(pid_tgid >> 32); // TGID
            evt.tgid = (u32)(pid_tgid >> 32);
            evt.uid = (u32)(uid_gid & 0xFFFFFFFF);
            evt.gid = (u32)(uid_gid >> 32);
            
            struct task_struct *task = (struct task_struct *)bpf_get_current_task();
            struct task_struct *group_leader;
            bpf_probe_read_kernel(&group_leader, sizeof(group_leader), &task->group_leader);
            bpf_probe_read_kernel(&evt.start_time, sizeof(evt.start_time), &group_leader->start_time);
            
            evt.timestamp_ns = bpf_ktime_get_ns();
            bpf_get_current_comm(&evt.comm, sizeof(evt.comm));

            events.perf_submit(skops, &evt, sizeof(evt));
        }
    }
    return 1;
}
