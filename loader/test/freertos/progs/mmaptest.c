/* /bin/mmaptest — map a romfs file READ-ONLY + shared, demand-paged, and read it
 * straight from the mapping (no read()-into-malloc copy). Proves the mmap'd bytes
 * match a read() of the same file, and that a multi-page file demand-pages in
 * (touching its last page faults a second page into the RO window). Uses inline
 * syscalls (usys.h) — no libc. */
#include "usys.h"

static int  slen(const char *s) { int n = 0; while (s[n]) n++; return n; }
static void put(const char *s)  { sys_write(1, s, slen(s)); }
static int  eq(const char *a, const char *b, int n)
{ for (int i = 0; i < n; i++) if (a[i] != b[i]) return 0; return 1; }

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;

    /* small file: verify mmap bytes == read() bytes (zero-copy correctness) */
    int fd = sys_open("/OS/etc/motd", 0);
    if (fd < 0) { put("mmaptest: open motd failed\n"); return; }
    long sz = sys_lseek(fd, 0, 2); sys_lseek(fd, 0, 0);
    const char *m = (const char *)sys_mmap(fd, 0, 0);
    if (!m) { put("mmaptest: mmap motd failed\n"); return; }

    char buf[128]; int n = (int)sz; if (n > 128) n = 128;
    sys_read(fd, buf, (unsigned)n);                 /* a copy, to compare against */

    char line[80]; int i = 0;
    while (i < n && i < 79 && m[i] != '\n') { line[i] = m[i]; i++; }   /* read via the mapping */
    line[i] = 0;
    put("mmaptest: mmap'd /OS/etc/motd, first line: \""); put(line); put("\"\n");
    put(eq(m, buf, n) ? "mmaptest: mmap bytes == read() bytes (zero-copy OK)\n"
                      : "mmaptest: MISMATCH\n");
    sys_munmap((void *)m, (unsigned)sz);
    sys_close(fd);

    /* multi-page file: map the font, touch first + last byte to demand-page both
     * its first and a later page through the RO window (proves multi-page mmap). */
    int ff = sys_open("/OS/Fonts/AovelSansRounded.ttf", 0);
    if (ff >= 0) {
        long fsz = sys_lseek(ff, 0, 2);
        const volatile unsigned char *fp = (const volatile unsigned char *)sys_mmap(ff, 0, 0);
        if (fp && fsz > 4096) {
            volatile unsigned char first = fp[0], last = fp[fsz - 1];  /* page 0 + last page */
            (void)first; (void)last;
            put("mmaptest: mmap'd font, touched first + last page (multi-page demand) OK\n");
            sys_munmap((void *)fp, (unsigned)fsz);
        }
        sys_close(ff);
    }
    /* "mmaptest ro": prove the mapping is READ-ONLY — writing to it faults and the
     * OS kills us (so the final line should NOT print). */
    if (argc > 1 && argv[1][0] == 'r') {
        int wf = sys_open("/OS/etc/motd", 0);
        char *w = (char *)sys_mmap(wf, 0, 0);
        if (w) {
            put("mmaptest: writing to the RO mapping (expect a kill)...\n");
            w[0] = 'X';                                  /* -> fatal: read-only */
            put("mmaptest: ERROR — write to RO mapping SUCCEEDED\n");
        }
    }
    put("mmaptest: done\n");
}
