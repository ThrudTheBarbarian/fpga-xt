/*
 * init.c — /System/bin/init: the first program under multitasking (PL0). The kernel
 * hands it the boot-script paths (argv, sorted by NN). For each, init reads the
 * script's "#!" line to find the interpreter (#!/bin/sh -> toysh, #!/bin/lua ->
 * the Lua interpreter; the kernel resolves either to the romfs) and spawns
 * "interp script". One process per script -> variable separation. Bare usys.h
 * (no libc) so it's tiny + fast.
 */
#include "usys.h"

/* read the first line of `path` into buf (NUL-terminated); returns length or -1. */
static int read_head(const char *path, char *buf, int max)
{
    int fd = sys_open(path, 0);
    if (fd < 0) return -1;
    long k = sys_read(fd, buf, max - 1);
    sys_close(fd);
    if (k < 0) k = 0;
    buf[k] = 0;
    return (int)k;
}

static void set_default(char *interp)
{
    const char *d = "/bin/sh"; int i = 0;
    while (d[i]) { interp[i] = d[i]; i++; } interp[i] = 0;
}

static void w(const char *s) { unsigned n = 0; while (s[n]) n++; sys_write(1, s, n); }

/* one boot-script status line:  "  <name> .......... [ OK ]"  (green) or [FAIL] (red).
 * name = the script basename with any leading "NN-" order prefix stripped. */
static void status(const char *script, int ok)
{
    const char *base = script;
    for (const char *p = script; *p; p++) if (*p == '/') base = p + 1;
    if (base[0] >= '0' && base[0] <= '9') {              /* strip an NN- order prefix */
        const char *q = base; while (*q >= '0' && *q <= '9') q++;
        if (*q == '-') base = q + 1;
    }
    w("  ");
    int col = 2;
    for (const char *p = base; *p; p++) { char c[2] = { *p, 0 }; w(c); col++; }
    while (col < 40) { w("."); col++; }
    w(ok ? " \033[32m[ OK ]\033[0m\n" : " \033[31m[FAIL]\033[0m\n");
}

void _app_entry(int argc, char **argv)
{
    for (int a = 1; a < argc; a++) {
        const char *script = argv[a];
        char interp[64];
        set_default(interp);

        char head[96];
        int k = read_head(script, head, sizeof head);
        if (k >= 2 && head[0] == '#' && head[1] == '!') {     /* parse the shebang */
            int p = 2;
            while (head[p] == ' ' || head[p] == '\t') p++;
            int j = 0;
            while (p < k && head[p] && head[p] != '\n' && head[p] != '\r'
                   && head[p] != ' ' && j < 63)
                interp[j++] = head[p++];
            interp[j] = 0;
            if (j == 0) set_default(interp);
        }

        char *av[3] = { interp, (char *)script, 0 };
        long pid = sys_spawn(interp, 2, av);   /* separate process per script (variable separation) */
        long code = -1;
        if (pid >= 0) code = sys_waitpid((int)pid);  /* run boot scripts to completion, IN ORDER (NN-sorted); */
                                                     /* a long-running daemon in a script uses `&` to detach */
        status(script, pid >= 0 && code == 0);       /* [ OK ] / [FAIL] per script */
    }

    /* Every boot script has run. TELL THE KERNEL — it is holding the console for us, and
     * since we are about to go resident it can never find this out by waiting for us to
     * exit. (It used to. The day init stopped exiting, the login shell and the kernel menu
     * stopped starting, and the machine came up with no console at all.) */
    sys_boot_done();

    /* Do NOT exit. init(1) stays resident as the ULTIMATE REAPER.
     *
     * When any process dies, the kernel re-parents its children here. Without a resident
     * init they had no parent at all, and worse: if the dead parent had registered a
     * waitpid on a child, that child's `waited` flag stayed set forever -- and the lazy
     * orphan sweeper deliberately skips `waited` processes, believing someone is coming
     * for them. Nobody was. The process sat in `ps` for the life of the machine, looking
     * alive: `kill -0` said "No such process" while `ps` still listed it. ("Two desktops
     * are running" -- one of them had been dead for ten minutes.)
     *
     * waitpid(-1) blocks until any child exits, reaps it, and returns -ECHILD when there
     * is nothing left to wait for -- so this loop costs nothing while the machine is idle. */
    for (;;) {
        long r = sys_waitpid(-1);
        if (r < 0) sys_nanosleep(200000);  /* usec: 200ms. No children right now; check again shortly. */
    }
}
