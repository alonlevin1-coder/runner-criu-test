#include <uapi/linux/ptrace.h>
#include <linux/sched.h>
#include <uapi/linux/bpf.h>

/*
 * Event types:
 *   1 = EXECVE  - a process called execve (new image loaded)
 *   2 = FORK    - a new child process was spawned
 *   3 = EXIT    - a process (thread-group leader) exited
 *
 * Identity key: (tgid, group_leader->start_time)
 * This is stable across the entire process lifetime and matches what the
 * network tracer uses, so the aggregator can correlate connections to lineage.
 */

/* ---- event structs ---- */

struct execve_event_t {
    u32 event_type;       /* 1 */
    u32 pid;              /* TGID of process calling execve */
    u32 ppid;             /* TGID of parent */
    u64 start_time;       /* group_leader->start_time (identity timestamp) */
    u64 p_start_time;     /* parent group_leader->start_time */
    char comm[16];        /* short comm name at execve time */
    char exe[128];        /* path of binary being exec'd */
    char argv[10][64];    /* first 10 argv strings */
};

struct fork_event_t {
    u32 event_type;           /* 2 */
    u32 parent_pid;           /* parent TGID */
    u32 child_pid;            /* child TGID */
    u64 parent_start_time;    /* parent group_leader->start_time */
    u64 child_start_time;     /* child group_leader->start_time */
    char parent_comm[16];
    char child_comm[16];
};

struct exit_event_t {
    u32 event_type;    /* 3 */
    u32 pid;           /* TGID of exiting process */
    u64 start_time;    /* group_leader->start_time */
};

/*
 * BPF_PERCPU_ARRAY keeps allocations off the BPF stack (512-byte limit).
 * One slot per CPU is enough because BPF programs are non-preemptible.
 */
BPF_PERCPU_ARRAY(execve_scratch, struct execve_event_t, 1);
BPF_PERCPU_ARRAY(fork_scratch,   struct fork_event_t,   1);
BPF_PERCPU_ARRAY(exit_scratch,   struct exit_event_t,   1);

/* Single shared perf ring-buffer; userspace demuxes by event_type */
BPF_PERF_OUTPUT(events);

/* ---- execve hook ---- */

static __always_inline int handle_execve(void *ctx, void *filename_ptr, void *argv_ptr) {
    u32 zero = 0;
    struct execve_event_t *evt = execve_scratch.lookup(&zero);
    if (!evt) return 0;

    __builtin_memset(evt, 0, sizeof(*evt));
    evt->event_type = 1;

    struct task_struct *task = (struct task_struct *)bpf_get_current_task();

    evt->pid = bpf_get_current_pid_tgid() >> 32;

    struct task_struct *gl;
    bpf_probe_read_kernel(&gl, sizeof(gl), &task->group_leader);
    bpf_probe_read_kernel(&evt->start_time, sizeof(evt->start_time), &gl->start_time);

    struct task_struct *parent;
    bpf_probe_read_kernel(&parent, sizeof(parent), &task->real_parent);
    bpf_probe_read_kernel(&evt->ppid, sizeof(evt->ppid), &parent->tgid);

    struct task_struct *pgl;
    bpf_probe_read_kernel(&pgl, sizeof(pgl), &parent->group_leader);
    bpf_probe_read_kernel(&evt->p_start_time, sizeof(evt->p_start_time), &pgl->start_time);

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
            bpf_probe_read_user(&argp, sizeof(argp), (void *)argv_ptr + i * sizeof(void *));
            if (!argp) break;
            bpf_probe_read_user_str(&evt->argv[i], sizeof(evt->argv[i]), argp);
        }
    }

    events.perf_submit(ctx, evt, sizeof(*evt));
    return 0;
}

int kprobe____x64_sys_execve(struct pt_regs *ctx) {
    struct pt_regs *regs;
    bpf_probe_read_kernel(&regs, sizeof(regs), &ctx->di);
    const char *filename;
    bpf_probe_read_kernel(&filename, sizeof(filename), &regs->di);
    const char **argv;
    bpf_probe_read_kernel(&argv, sizeof(argv), &regs->si);
    return handle_execve(ctx, (void *)filename, (void *)argv);
}

int kprobe____x64_sys_execveat(struct pt_regs *ctx) {
    struct pt_regs *regs;
    bpf_probe_read_kernel(&regs, sizeof(regs), &ctx->di);
    const char *pathname;
    bpf_probe_read_kernel(&pathname, sizeof(pathname), &regs->si);
    const char **argv;
    bpf_probe_read_kernel(&argv, sizeof(argv), &regs->dx);
    return handle_execve(ctx, (void *)pathname, (void *)argv);
}

/* ---- fork hook ---- */
/*
 * wake_up_new_task is called in the parent's context right after the child
 * task_struct is fully set up, making it the ideal place to record the
 * parent→child relationship.
 */
int kprobe__wake_up_new_task(struct pt_regs *ctx, struct task_struct *child) {
    u32 zero = 0;
    struct fork_event_t *evt = fork_scratch.lookup(&zero);
    if (!evt) return 0;

    /* No memset – we fill every field explicitly to avoid LLVM optimizer bugs */
    evt->event_type = 2;

    struct task_struct *parent = (struct task_struct *)bpf_get_current_task();

    u32 ptgid, ctgid;
    bpf_probe_read_kernel(&ptgid, sizeof(ptgid), &parent->tgid);
    bpf_probe_read_kernel(&ctgid,  sizeof(ctgid),  &child->tgid);
    
    if (ptgid == ctgid) return 0; // Ignore thread creation events

    evt->parent_pid = ptgid;
    evt->child_pid = ctgid;

    struct task_struct *pgl, *cgl;
    bpf_probe_read_kernel(&pgl, sizeof(pgl), &parent->group_leader);
    bpf_probe_read_kernel(&cgl, sizeof(cgl), &child->group_leader);
    bpf_probe_read_kernel(&evt->parent_start_time, sizeof(evt->parent_start_time), &pgl->start_time);
    bpf_probe_read_kernel(&evt->child_start_time,  sizeof(evt->child_start_time),  &cgl->start_time);

    bpf_get_current_comm(&evt->parent_comm, sizeof(evt->parent_comm));
    bpf_probe_read_kernel_str(&evt->child_comm, sizeof(evt->child_comm), child->comm);

    events.perf_submit(ctx, evt, sizeof(*evt));
    return 0;
}

/* ---- exit hook ---- */
/*
 * do_exit is called for every thread. We only emit an event for the thread-group
 * leader (pid == tgid) so the aggregator sees exactly one EXIT per process.
 */
int kprobe__do_exit(struct pt_regs *ctx) {
    u32 zero = 0;
    struct exit_event_t *evt = exit_scratch.lookup(&zero);
    if (!evt) return 0;

    struct task_struct *task = (struct task_struct *)bpf_get_current_task();

    u32 pid, tgid;
    bpf_probe_read_kernel(&pid,  sizeof(pid),  &task->pid);
    bpf_probe_read_kernel(&tgid, sizeof(tgid), &task->tgid);
    if (pid != tgid) return 0; /* skip non-leader threads */

    evt->event_type = 3;
    bpf_probe_read_kernel(&evt->pid,        sizeof(evt->pid),        &task->tgid);
    bpf_probe_read_kernel(&evt->start_time, sizeof(evt->start_time), &task->start_time);

    events.perf_submit(ctx, evt, sizeof(*evt));
    return 0;
}
