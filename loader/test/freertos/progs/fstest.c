/* /bin/fstest — prove the cwd + mkdir/rename/relative-path foundation.
 * Default base /tmp (ramfs, qemu); pass /OS on HW for the SD/fatfs path.
 * Links standalone (raw syscalls, no libc). */
#include "usys.h"

#define O_RDONLY 0x0000
#define O_RDWR   0x0002
#define O_CREAT  0x0200
#define O_TRUNC  0x0400

static unsigned slen(const char *s) { unsigned n = 0; while (s[n]) n++; return n; }
static void put(const char *s) { sys_write(1, s, slen(s)); }
static int  fails;
static void check(const char *w, int ok) {
    put(ok ? "  [PASS] " : "  [FAIL] "); put(w); put("\n"); if (!ok) fails++;
}
static int streq(const char *a, const char *b)
{ while (*a && *a == *b) { a++; b++; } return *a == 0 && *b == 0; }
static char *J(const char *base, const char *name) {
    static char bufs[4][128]; static int r; char *d = bufs[r = (r + 1) & 3]; int i = 0;
    while (base[i] && i < 100) { d[i] = base[i]; i++; }
    d[i++] = '/'; int j = 0; while (name[j] && i < 127) { d[i++] = name[j++]; } d[i] = 0; return d;
}

void _app_entry(int argc, char **argv) {
    const char *B = (argc > 1) ? argv[1] : "/tmp";
    char cwd[128]; struct xt_stat st;
    char *d1 = J(B, "d1");
    put("fstest: cwd/mkdir/rename on "); put(B); put("\n");

    /* every process starts at the root */
    sys_getcwd(cwd, sizeof cwd);
    check("initial cwd is /", streq(cwd, "/"));

    /* mkdir + stat-is-dir */
    sys_unlink(J(d1, "g.txt")); sys_unlink(J(d1, "f.txt")); sys_unlink(d1);   /* fresh */
    check("mkdir", sys_mkdir(d1, 0755) == 0);
    check("stat dir is a directory", sys_stat(d1, &st) == 0 && (st.mode & XT_S_IFMT) == XT_S_IFDIR);

    /* chdir + getcwd */
    check("chdir into it", sys_chdir(d1) == 0);
    sys_getcwd(cwd, sizeof cwd);
    check("getcwd == the dir", streq(cwd, d1));

    /* create/stat a file by RELATIVE path (resolves against cwd) */
    long fd = sys_open("f.txt", O_CREAT | O_TRUNC | O_RDWR);
    if (fd >= 0) { sys_write((int)fd, "hi\n", 3); sys_close((int)fd); }
    check("create relative file", fd >= 0);
    check("stat relative file", sys_stat("f.txt", &st) == 0 && (st.mode & XT_S_IFMT) == XT_S_IFREG);

    /* rename (relative, within cwd) */
    check("rename f.txt -> g.txt", sys_rename("f.txt", "g.txt") == 0);
    check("old name gone", sys_stat("f.txt", &st) != 0);
    check("new name exists", sys_stat("g.txt", &st) == 0);

    /* chdir .. — path normalization */
    check("chdir ..", sys_chdir("..") == 0);
    sys_getcwd(cwd, sizeof cwd);
    check("getcwd after .. == base", streq(cwd, B));

    /* cleanup (best effort) */
    sys_unlink(J(d1, "g.txt")); sys_unlink(d1);

    put(fails ? "fstest: FAIL\n" : "fstest: all PASS\n");
}
