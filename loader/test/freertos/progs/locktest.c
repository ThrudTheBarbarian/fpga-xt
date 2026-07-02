/* /bin/locktest — prove the lockfs (advisory locks-as-files @ /OS/Var/Locks).
 *
 * Exercises the whole mechanism from user space: acquire, refuse-while-held,
 * read-back the holder id, release, re-acquire, and refuse-to-read once free.
 * Cross-process safety follows from the lockfd living in the holder's fd table
 * (reap frees it); this checks the exclusion + holder-readback that SQLite's VFS
 * lock methods are built on.  Links standalone (raw syscalls, no libc). */
#include "usys.h"

#define O_RDONLY 0x0000
#define O_WRONLY 0x0001
#define O_CREAT  0x0200

static unsigned slen(const char *s) { unsigned n = 0; while (s[n]) n++; return n; }
static void put(const char *s) { sys_write(1, s, slen(s)); }
static int  fails;
static void check(const char *what, int ok) {
    put(ok ? "  [PASS] " : "  [FAIL] "); put(what); put("\n");
    if (!ok) fails++;
}

void _app_entry(int argc, char **argv) {
    (void)argc; (void)argv;
    const char *L = "/OS/Var/Locks/locktest";
    put("locktest: lockfs @ /OS/Var/Locks\n");

    long a = sys_open(L, O_CREAT | O_WRONLY);          /* acquire */
    check("acquire lock", a >= 0);

    long b = sys_open(L, O_CREAT | O_WRONLY);          /* held -> must be refused */
    check("re-acquire held lock is refused", b < 0);
    if (b >= 0) sys_close((int)b);

    long r = sys_open(L, O_RDONLY);                    /* read the holder */
    check("holder is readable while held", r >= 0);
    if (r >= 0) {
        char id[32]; long n = sys_read((int)r, id, sizeof id - 1);
        if (n > 0) { id[n] = 0; put("  holder task id = "); put(id); }
        check("holder id read back", n > 0);
        sys_close((int)r);
    }

    if (a >= 0) sys_close((int)a);                     /* release */
    put("  released\n");

    long d = sys_open(L, O_RDONLY);                    /* now free -> no such lock */
    check("read of released lock is refused", d < 0);
    if (d >= 0) sys_close((int)d);

    long c = sys_open(L, O_CREAT | O_WRONLY);          /* re-acquire after release */
    check("re-acquire after release", c >= 0);
    if (c >= 0) sys_close((int)c);

    put(fails ? "locktest: FAIL\n" : "locktest: all PASS\n");
}
