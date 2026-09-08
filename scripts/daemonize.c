#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/wait.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <cmd> [args...]\n", argv[0]);
        return 1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork 1");
        return 1;
    }
    if (pid > 0) {
        // Parent: wait for intermediate child
        int status = 0;
        waitpid(pid, &status, 0);
        return WEXITSTATUS(status);
    }

    // First child: setsid to become session and process group leader
    if (setsid() < 0) {
        perror("setsid");
        _exit(1);
    }

    // Second fork to ensure we cannot regain a controlling terminal
    pid = fork();
    if (pid < 0) {
        perror("fork 2");
        _exit(1);
    }
    if (pid > 0) {
        // Intermediate child exits immediately, reparenting grandchild to init
        _exit(0);
    }

    // Grandchild (the detached daemon):
    // Redirect stdio to /tmp/daemon_helper.log
    int log_fd = open("/tmp/daemon_helper.log", O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (log_fd >= 0) {
        dup2(log_fd, STDIN_FILENO);
        dup2(log_fd, STDOUT_FILENO);
        dup2(log_fd, STDERR_FILENO);
        if (log_fd > STDERR_FILENO) close(log_fd);
    } else {
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            if (devnull > STDERR_FILENO) close(devnull);
        }
    }

    // Close any other inherited open file descriptors >= 3
    for (int fd = 3; fd < 256; fd++) {
        close(fd);
    }

    execvp(argv[1], &argv[1]);
    perror("execvp");
    _exit(127);
}
