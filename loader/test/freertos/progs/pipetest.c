/* /bin/pipetest — SYS_pipe + SYS_spawn_fd kernel primitives, raw (no libc):
 *   1. parent -> pipe -> child cat (child stdin = pipe read end)
 *   2. child ls -> pipe -> parent (child stdout = pipe write end)
 *   3. EOF propagation: reader sees 0 once the last writer closes
 * Run: pipetest   (qemu or HW; only needs /System/bin/{cat,ls}) */
#include "usys.h"

static void put(const char *s) { unsigned n = 0; while (s[n]) n++; sys_write(1, s, n); }

static int fails;
static void check(int ok, const char *what)
{
    put(ok ? "  [PASS] " : "  [FAIL] ");
    put(what);
    put("\n");
    if (!ok) fails++;
}

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    put("pipetest: SYS_pipe + SYS_spawn_fd\n");

    /* 1: parent writes, child cat reads (stdin = read end) and echoes */
    {
        int pfd[2];
        check(sys_pipe(pfd) == 0, "pipe() allocates two fds");
        const char *msg = "hello through a pipe\n";
        unsigned mlen = 0; while (msg[mlen]) mlen++;
        check(sys_write(pfd[1], msg, mlen) == (long)mlen, "write into the pipe");
        char *av[] = { "cat", 0 };
        int fds[4] = { pfd[0], -1, -1, ~0 };   /* mask all: only stdio passes */
        long pid = sys_spawn_fd("/System/bin/cat", av, fds);
        check(pid > 0, "spawn cat with stdin = pipe read end");
        sys_close(pfd[0]);
        sys_close(pfd[1]);                 /* last writer -> cat sees EOF, exits */
        if (pid > 0) check(sys_waitpid((int)pid) == 0, "cat exited 0 (echoed the line above)");
    }

    /* 2: child ls writes into the pipe, parent reads */
    {
        int pfd[2];
        check(sys_pipe(pfd) == 0, "second pipe");
        char *av[] = { "ls", "/System/bin", 0 };
        int fds[4] = { -1, pfd[1], -1, ~0 };   /* mask all: only stdio passes */
        long pid = sys_spawn_fd("/System/bin/ls", av, fds);
        check(pid > 0, "spawn ls with stdout = pipe write end");
        sys_close(pfd[1]);                 /* parent's write end: EOF comes from ls exiting */
        char buf[256]; long n, total = 0;
        while ((n = sys_read(pfd[0], buf, sizeof buf)) > 0) total += n;
        check(n == 0, "read hit EOF after ls exited");
        check(total > 50, "captured ls output through the pipe");
        sys_close(pfd[0]);
        if (pid > 0) sys_waitpid((int)pid);
    }

    put(fails ? "pipetest: FAILURES\n" : "pipetest: all PASS\n");
    sys_exit(fails);
}
