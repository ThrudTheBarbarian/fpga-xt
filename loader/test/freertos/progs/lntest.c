/* /bin/lntest — prove POSIX symlinks. Default base /tmp (ramfs, works on qemu);
 * pass /OS on HW to exercise the SD/fatfs path (XTLK magic + SYSTEM attr) — the
 * resolver + syscalls are identical, only the driver differs.
 *
 * Exercises: create, readlink, lstat-vs-stat (link vs target), open-through
 * (follow), a relative link, an absolute link, a chained link, a dangling link,
 * and a self-referential loop (must fail via the ELOOP guard). Ends with a mini
 * `ls -l` printing `name -> target` — the same lstat + readlink that busybox's
 * real `ls -l` will use. Links standalone (raw syscalls). */
#include "usys.h"

#define O_RDONLY 0x0000
#define O_WRONLY 0x0001
#define O_RDWR   0x0002
#define O_CREAT  0x0200
#define O_TRUNC  0x0400

static unsigned slen(const char *s) { unsigned n = 0; while (s[n]) n++; return n; }
static void put(const char *s) { sys_write(1, s, slen(s)); }
static int  fails;
static void check(const char *what, int ok) {
    put(ok ? "  [PASS] " : "  [FAIL] "); put(what); put("\n");
    if (!ok) fails++;
}
static int streq(const char *a, const char *b)
{ while (*a && *a == *b) { a++; b++; } return *a == 0 && *b == 0; }

/* join base + "/" + name into a static rotating buffer (no libc). */
static char *J(const char *base, const char *name) {
    static char bufs[8][128]; static int r; char *d = bufs[r = (r + 1) & 7]; int i = 0;
    while (base[i] && i < 100) { d[i] = base[i]; i++; }
    d[i++] = '/';
    int j = 0; while (name[j] && i < 127) { d[i++] = name[j++]; }
    d[i] = 0; return d;
}

static void wr_file(const char *path, const char *data) {
    long fd = sys_open(path, O_CREAT | O_TRUNC | O_RDWR);
    if (fd >= 0) { sys_write((int)fd, data, slen(data)); sys_close((int)fd); }
}
static int rd_first(const char *path, char *buf, int n) {   /* open (follows links) + read */
    long fd = sys_open(path, O_RDONLY);
    if (fd < 0) return -1;
    long r = sys_read((int)fd, buf, (unsigned)(n - 1));
    sys_close((int)fd);
    if (r < 0) r = 0; buf[r] = 0; return (int)r;
}

void _app_entry(int argc, char **argv) {
    const char *B = (argc > 1) ? argv[1] : "/tmp";   /* base dir: /tmp (qemu) or /OS (HW) */
    char *tf = J(B, "target.txt");
    char *lf = J(B, "link.txt");        /* -> target.txt (relative) */
    char *la = J(B, "abs.txt");         /* -> <B>/target.txt (absolute) */
    char *lc = J(B, "chain.txt");       /* -> link.txt -> target.txt */
    char *ld = J(B, "dangling.txt");    /* -> nope.txt (missing) */
    char *ll = J(B, "loop.txt");        /* -> loop.txt (self) */
    char buf[128]; struct xt_stat st, lst;

    put("lntest: symlinks on "); put(B); put("\n");
    /* fresh scratch: unlink any leftovers (ignore errors), (re)create the target */
    sys_unlink(lf); sys_unlink(la); sys_unlink(lc); sys_unlink(ld); sys_unlink(ll); sys_unlink(tf);
    wr_file(tf, "hello symlink\n");
    check("create target file", sys_stat(tf, &st) == 0 && (st.mode & XT_S_IFMT) == XT_S_IFREG);

    /* --- create + readlink --------------------------------------------------- */
    check("symlink(relative)", sys_symlink("target.txt", lf) == 0);
    int n = (int)sys_readlink(lf, buf, sizeof buf);
    check("readlink returns target", n > 0 && streq(buf, "target.txt"));

    /* --- lstat vs stat: the link is a link; through it, a regular file -------- */
    check("lstat sees a symlink", sys_lstat(lf, &lst) == 0 && (lst.mode & XT_S_IFMT) == XT_S_IFLNK);
    check("stat follows to the file", sys_stat(lf, &st) == 0 && (st.mode & XT_S_IFMT) == XT_S_IFREG);

    /* --- open-through follows the link --------------------------------------- */
    buf[0] = 0; rd_first(lf, buf, sizeof buf);
    check("open(link) reads the target's bytes", streq(buf, "hello symlink\n"));

    /* --- absolute + chained links -------------------------------------------- */
    check("symlink(absolute)", sys_symlink(tf, la) == 0);      /* target = absolute <B>/target.txt */
    buf[0] = 0; rd_first(la, buf, sizeof buf);
    check("open(abs link) follows", streq(buf, "hello symlink\n"));

    check("symlink(chain -> link)", sys_symlink("link.txt", lc) == 0);
    buf[0] = 0; rd_first(lc, buf, sizeof buf);
    check("open(chained link) follows twice", streq(buf, "hello symlink\n"));

    /* --- dangling: lstat/readlink work, open fails --------------------------- */
    check("symlink(dangling)", sys_symlink("nope.txt", ld) == 0);
    check("lstat(dangling) is a link", sys_lstat(ld, &lst) == 0 && (lst.mode & XT_S_IFMT) == XT_S_IFLNK);
    check("open(dangling) fails", sys_open(ld, O_RDONLY) < 0);

    /* --- self loop: open must hit the ELOOP guard, not hang ------------------ */
    check("symlink(self loop)", sys_symlink("loop.txt", ll) == 0);
    check("open(loop) refused (ELOOP)", sys_open(ll, O_RDONLY) < 0);

    /* --- mini `ls -l`: name -> target for links ------------------------------ */
    put("  --- ls -l "); put(B); put(" ---\n");
    const char *names[] = { tf, lf, la, lc, ld, ll, 0 };
    for (int i = 0; names[i]; i++) {
        struct xt_stat s;
        if (sys_lstat(names[i], &s) != 0) continue;
        put("    "); put(names[i]);
        if ((s.mode & XT_S_IFMT) == XT_S_IFLNK) {
            char t[128]; int m = (int)sys_readlink(names[i], t, sizeof t);
            if (m > 0) { t[m] = 0; put(" -> "); put(t); }
        }
        put("\n");
    }

    put(fails ? "lntest: FAIL\n" : "lntest: all PASS\n");
}
