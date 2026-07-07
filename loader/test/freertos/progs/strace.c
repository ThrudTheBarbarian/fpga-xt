/* strace.c — /bin/strace: run a command with kernel syscall tracing enabled.
 *
 *   strace CMD [args...]
 *
 * Sets this process's trace flag (SYS_strace); children inherit it, so
 * `strace sshd` traces sshd, its sshd-session, and the login shell. The trace
 * (one line per syscall + return, decoded names) goes to the kernel log — read
 * it with `dmesg` (or cat /proc/kmsg). Bare usys, like sshd.c.
 */
#include "usys.h"

static void wrs(int fd, const char *s) { int n = 0; while (s[n]) n++; sys_write(fd, s, (unsigned)n); }

void _app_entry(int argc, char **argv)
{
    if (argc < 2) { wrs(2, "usage: strace CMD [args...]\n"); sys_exit(1); }

    /* resolve a bare command name to /bin/<cmd> (the shell already absolute-ized
     * a path with a slash) */
    const char *cmd = argv[1];
    char path[128];
    int has_slash = 0;
    for (const char *p = cmd; *p; p++) if (*p == '/') { has_slash = 1; break; }
    if (has_slash) {
        int i = 0; while (cmd[i] && i < 127) { path[i] = cmd[i]; i++; } path[i] = 0;
    } else {
        const char *pre = "/bin/"; int i = 0;
        while (pre[i]) { path[i] = pre[i]; i++; }
        for (int j = 0; cmd[j] && i < 127; j++) path[i++] = cmd[j];
        path[i] = 0;
    }

    sys_strace(1);                          /* trace me + children -> dmesg */

    int fds[4] = { -1, -1, -1, 0 };         /* CMD inherits our stdio */
    long pid = sys_spawn_fd(path, argv + 1, fds, 0);
    if (pid < 0) { wrs(2, "strace: cannot run "); wrs(2, path); wrs(2, "\n"); sys_exit(1); }
    long code = sys_waitpid((int)pid);
    wrs(2, "strace: done — read the trace with `dmesg`\n");
    sys_exit((int)code);
}
