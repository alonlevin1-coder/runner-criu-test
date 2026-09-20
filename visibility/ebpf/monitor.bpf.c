#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

struct execve_event_t {
    u32 event_type;
    u32 pid;
    u32 ppid;
    u64 start_time;
    u64 p_start_time;
    char comm[16];
    char exe[128];
    char argv[10][64];
} __attribute__((packed));

struct fork_event_t {
    u32 event_type;
    u32 parent_pid;
    u32 child_pid;
    u64 parent_start_time;
    u64 child_start_time;
    char parent_comm[16];
    char child_comm[16];
} __attribute__((packed));

struct exit_event_t {
    u32 event_type;
    u32 pid;
    u64 start_time;
} __attribute__((packed));

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct execve_event_t);
} execve_scratch SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct fork_event_t);
} fork_scratch SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct exit_event_t);
} exit_scratch SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERF_EVENT_ARRAY);
    __uint(key_size, sizeof(u32));
    __uint(value_size, sizeof(u32));
} events SEC(".maps");

static __always_inline int handle_execve(void *ctx, const char *filename_ptr, const char **argv_ptr)
{
    u32 zero = 0;
    struct execve_event_t *evt = bpf_map_lookup_elem(&execve_scratch, &zero);
    if (!evt)
        return 0;

    __builtin_memset(evt, 0, sizeof(*evt));
    evt->event_type = 1;

    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    evt->pid = bpf_get_current_pid_tgid() >> 32;
    evt->start_time = BPF_CORE_READ(task, group_leader, start_time);
    evt->ppid = BPF_CORE_READ(task, real_parent, tgid);
    evt->p_start_time = BPF_CORE_READ(task, real_parent, group_leader, start_time);
    bpf_get_current_comm(&evt->comm, sizeof(evt->comm));

    if (filename_ptr) {
        bpf_probe_read_user_str(&evt->exe, sizeof(evt->exe), filename_ptr);
        if (evt->exe[0] == '\0')
            bpf_probe_read_kernel_str(&evt->exe, sizeof(evt->exe), filename_ptr);
    }

    if (argv_ptr) {
        const char *argp = NULL;
        #pragma unroll
        for (int i = 0; i < 10; i++) {
            bpf_probe_read_user(&argp, sizeof(argp), &argv_ptr[i]);
            if (!argp)
                break;
            bpf_probe_read_user_str(&evt->argv[i], sizeof(evt->argv[i]), argp);
        }
    }

    bpf_perf_event_output(ctx, &events, BPF_F_CURRENT_CPU, evt, sizeof(*evt));
    return 0;
}

SEC("kprobe/__x64_sys_execve")
int kprobe_execve(struct pt_regs *ctx)
{
    struct pt_regs *regs = (struct pt_regs *)PT_REGS_PARM1(ctx);
    const char *filename = NULL;
    const char **argv = NULL;
    bpf_probe_read_kernel(&filename, sizeof(filename), &PT_REGS_PARM1(regs));
    bpf_probe_read_kernel(&argv, sizeof(argv), &PT_REGS_PARM2(regs));
    return handle_execve(ctx, filename, argv);
}

SEC("kprobe/__x64_sys_execveat")
int kprobe_execveat(struct pt_regs *ctx)
{
    struct pt_regs *regs = (struct pt_regs *)PT_REGS_PARM1(ctx);
    const char *pathname = NULL;
    const char **argv = NULL;
    bpf_probe_read_kernel(&pathname, sizeof(pathname), &PT_REGS_PARM2(regs));
    bpf_probe_read_kernel(&argv, sizeof(argv), &PT_REGS_PARM3(regs));
    return handle_execve(ctx, pathname, argv);
}

SEC("kprobe/wake_up_new_task")
int kprobe_wake_up_new_task(struct pt_regs *ctx)
{
    struct task_struct *child = (struct task_struct *)PT_REGS_PARM1(ctx);
    u32 zero = 0;
    struct fork_event_t *evt = bpf_map_lookup_elem(&fork_scratch, &zero);
    if (!evt)
        return 0;

    struct task_struct *parent = (struct task_struct *)bpf_get_current_task();
    u32 ptgid = BPF_CORE_READ(parent, tgid);
    u32 ctgid = BPF_CORE_READ(child, tgid);
    if (ptgid == ctgid)
        return 0;

    evt->event_type = 2;
    evt->parent_pid = ptgid;
    evt->child_pid = ctgid;
    evt->parent_start_time = BPF_CORE_READ(parent, group_leader, start_time);
    evt->child_start_time = BPF_CORE_READ(child, group_leader, start_time);
    bpf_get_current_comm(&evt->parent_comm, sizeof(evt->parent_comm));
    bpf_probe_read_kernel_str(&evt->child_comm, sizeof(evt->child_comm), &child->comm[0]);

    bpf_perf_event_output(ctx, &events, BPF_F_CURRENT_CPU, evt, sizeof(*evt));
    return 0;
}

SEC("kprobe/do_exit")
int kprobe_do_exit(struct pt_regs *ctx)
{
    u32 zero = 0;
    struct exit_event_t *evt = bpf_map_lookup_elem(&exit_scratch, &zero);
    if (!evt)
        return 0;

    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    u32 pid = BPF_CORE_READ(task, pid);
    u32 tgid = BPF_CORE_READ(task, tgid);
    if (pid != tgid)
        return 0;

    evt->event_type = 3;
    evt->pid = tgid;
    evt->start_time = BPF_CORE_READ(task, start_time);
    bpf_perf_event_output(ctx, &events, BPF_F_CURRENT_CPU, evt, sizeof(*evt));
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
