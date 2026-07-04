/* /bin/pipetest — SYS_pipe + SYS_spawn_fd kernel primitives, raw (no libc):
 *   1. parent -> pipe -> child cat (child stdin = pipe read end)
 *   2. child ls -> pipe -> parent (child stdout = pipe write end)
 *   3. EOF propagation: reader sees 0 once the last writer closes
 * Run: pipetest   (qemu or HW; only needs /System/bin/{cat,ls}) */
#include "usys.h"

static void put(const char *s) { unsigned n = 0; while (s[n]) n++; sys_write(1, s, n); }

static void putn(const char *tag, long v)
{
    char t[12]; int n = 0;
    put(tag);
    if (v < 0) { put("-"); v = -v; }
    if (!v) t[n++] = '0';
    while (v) { t[n++] = (char)('0' + v % 10); v /= 10; }
    while (n) sys_write(1, &t[--n], 1);
    put("\n");
}

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
        long pid = sys_spawn_fd("/System/bin/cat", av, fds, 0);
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
        long pid = sys_spawn_fd("/System/bin/ls", av, fds, 0);
        check(pid > 0, "spawn ls with stdout = pipe write end");
        sys_close(pfd[1]);                 /* parent's write end: EOF comes from ls exiting */
        char buf[256]; long n, total = 0;
        while ((n = sys_read(pfd[0], buf, sizeof buf)) > 0) total += n;
        check(n == 0, "read hit EOF after ls exited");
        check(total > 50, "captured ls output through the pipe");
        sys_close(pfd[0]);
        if (pid > 0) sys_waitpid((int)pid);
    }

    /* 3: file-redirected stdio — child echo writes into fd1 = a ramfs file */
    {
        long ffd = sys_open("/tmp/pt_redir", 0x0601 /* WRONLY|CREAT|TRUNC */);
        check(ffd >= 3, "open /tmp/pt_redir for writing");
        char *av[] = { "echo", "filetest", 0 };
        int fds[4] = { -1, (int)ffd, -1, ~0 };
        long pid = sys_spawn_fd("/System/bin/echo", av, fds, 0);
        check(pid > 0, "spawn echo with stdout = file fd");
        if (pid > 0) putn("  (echo exit=", sys_waitpid((int)pid));
        struct xt_stat xs;
        if (sys_stat("/tmp/pt_redir", &xs) == 0) putn("  (post-wait size=", (long)xs.size);
        sys_close((int)ffd);
        char buf[64]; long n = -1;
        long rfd = sys_open("/tmp/pt_redir", 0);
        if (rfd >= 0) { n = sys_read((int)rfd, buf, sizeof buf); sys_close((int)rfd); }
        check(n == 9, "file holds echo's 9 bytes (filetest\\n)");
        if (n != 9) putn("  (got n=", n);
        /* 4: parent-side dup2 of a file onto stdout, write silently, restore */
        ffd = sys_open("/tmp/pt_redir2", 0x0601);
        long sfd = sys_dup2(1, 10);                    /* save console at 10 */
        long d1 = sys_dup2((int)ffd, 1);
        long w1 = sys_write(1, "direct\n", 7);         /* -> the file */
        long d2 = sys_dup2(10, 1);                     /* restore console */
        sys_close(10);
        check(sfd == 10, "dup2 saved console stdout at fd 10");
        check(d1 == 1, "dup2 file onto stdout");
        check(w1 == 7, "write through redirected stdout");
        check(d2 == 1, "restore console stdout");
        rfd = sys_open("/tmp/pt_redir2", 0);
        n = -1;
        if (rfd >= 0) { n = sys_read((int)rfd, buf, sizeof buf); sys_close((int)rfd); }
        check(n == 7, "file holds the 7 dup2-redirected bytes");
        if (n != 7) putn("  (got n=", n);
        sys_unlink("/tmp/pt_redir");     /* don't exhaust the ramfs node table */
        sys_unlink("/tmp/pt_redir2");
    }

    /* 5: non-blocking waitpid (WNOHANG): a child parked reading an empty pipe
     * polls as running; after EOF it exits and the poll reaps it */
    {
        int pfd[2];
        sys_pipe(pfd);
        char *av[] = { "cat", 0 };
        int fds[4] = { pfd[0], -1, -1, ~0 };
        long pid = sys_spawn_fd("/System/bin/cat", av, fds, 0);
        sys_close(pfd[0]);
        check(sys_waitpid_nb((int)pid) == -11, "poll: child blocked on the pipe = still running");
        sys_close(pfd[1]);                 /* EOF -> cat exits */
        long code = -11;
        for (int spin = 0; spin < 1000000 && code == -11; spin++)
            code = sys_waitpid_nb((int)pid);
        check(code == 0, "poll: reaped the exited child, code 0");
        check(sys_waitpid_nb((int)pid) == -1, "poll: already-reaped pid is gone");
    }

    put(fails ? "pipetest: FAILURES\n" : "pipetest: all PASS\n");
    sys_exit(fails);
}
