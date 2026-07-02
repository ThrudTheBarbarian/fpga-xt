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
    int fd = sys_open("/System/etc/motd", 0);
    if (fd < 0) { put("mmaptest: open motd failed\n"); return; }
    long sz = sys_lseek(fd, 0, 2); sys_lseek(fd, 0, 0);
    const char *m = (const char *)sys_mmap(fd, 0, 0);
    if (!m) { put("mmaptest: mmap motd failed\n"); return; }

    char buf[128]; int n = (int)sz; if (n > 128) n = 128;
    sys_read(fd, buf, (unsigned)n);                 /* a copy, to compare against */

    char line[80]; int i = 0;
    while (i < n && i < 79 && m[i] != '\n') { line[i] = m[i]; i++; }   /* read via the mapping */
    line[i] = 0;
    put("mmaptest: mmap'd /System/etc/motd, first line: \""); put(line); put("\"\n");
    put(eq(m, buf, n) ? "mmaptest: mmap bytes == read() bytes (zero-copy OK)\n"
                      : "mmaptest: MISMATCH\n");
    sys_munmap((void *)m, (unsigned)sz);
    sys_close(fd);

    /* multi-page file: map the font, touch first + last byte to demand-page both
     * its first and a later page through the RO window (proves multi-page mmap). */
    int ff = sys_open("/System/Fonts/AovelSansRounded.ttf", 0);
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
    /* backing-store mmap (ramfs, /tmp): create a >4 KB file, then mmap it RO and read it
     * through the mapping. Unlike romfs (already resident), an SD/ramfs file is EAGER-
     * filled into pool pages at mmap() time by the fs task — fs-pagecache step 3c-3. */
    {
        static unsigned char pat[9000];
        for (int i = 0; i < 9000; i++) pat[i] = (unsigned char)(i * 5 + 1);
        int wf = sys_open("/tmp/mm", 0x601);            /* O_WRONLY|O_CREAT|O_TRUNC */
        if (wf >= 0) { sys_write(wf, pat, 9000); sys_close(wf); }
        int rf = sys_open("/tmp/mm", 0);
        long msz = rf >= 0 ? sys_lseek(rf, 0, 2) : -1;
        const unsigned char *mm = rf >= 0 ? (const unsigned char *)sys_mmap(rf, 0, 0) : 0;
        int ok = (mm && msz == 9000);
        if (mm) for (int i = 0; i < 9000; i++) if (mm[i] != (unsigned char)(i * 5 + 1)) { ok = 0; break; }
        put(ok ? "mmaptest: /tmp mmap (ramfs eager-fill) bytes match -> OK\n"
               : "mmaptest: /tmp mmap FAIL\n");
        if (mm) sys_munmap((void *)mm, (unsigned)msz);
        if (rf >= 0) sys_close(rf);
    }

    /* RW mmap write-back (dirty-via-fault) with CLOSE-BEFORE-MUNMAP: create an 8000-byte
     * (2-page) file, mmap it WRITABLE, close the fd FIRST, then store into two pages
     * through the mapping and munmap. POSIX: the mapping keeps its own reference, so the
     * writes must persist even though the fd is closed — the write-back re-opens the file
     * by its recorded path (fs-pagecache 3c-3b). Reopen and confirm writes persisted AND
     * untouched bytes survived. */
    {
        static unsigned char z[8000], rr[8000];
        for (int i = 0; i < 8000; i++) z[i] = (unsigned char)i;
        int cf = sys_open("/tmp/rw", 0x601);            /* O_WRONLY|O_CREAT|O_TRUNC */
        if (cf >= 0) { sys_write(cf, z, 8000); sys_close(cf); }
        int mf = sys_open("/tmp/rw", 2);                /* O_RDWR -> writable mapping */
        unsigned char *w = mf >= 0 ? (unsigned char *)sys_mmap(mf, 0, 0) : 0;
        int ok = (w != 0);
        if (mf >= 0) sys_close(mf);                     /* close BEFORE writing/munmap (the hard case) */
        if (w) { w[10] = 0xAA; w[5000] = 0xBB; sys_munmap(w, 8000); }   /* dirty page 0 + page 1 */
        int vf = sys_open("/tmp/rw", 0);
        long got = vf >= 0 ? sys_read(vf, rr, 8000) : 0;
        if (vf >= 0) sys_close(vf);
        ok = ok && got == 8000 && rr[10] == 0xAA && rr[5000] == 0xBB
                && rr[11] == (unsigned char)11 && rr[4999] == (unsigned char)4999;   /* untouched survived */
        put(ok ? "mmaptest: /tmp RW mmap write-back (dirty-via-fault) -> OK\n"
               : "mmaptest: /tmp RW mmap FAIL\n");
    }

    /* "mmaptest ro": prove the mapping is READ-ONLY — writing to it faults and the
     * OS kills us (so the final line should NOT print). */
    if (argc > 1 && argv[1][0] == 'r') {
        int wf = sys_open("/System/etc/motd", 0);
        char *w = (char *)sys_mmap(wf, 0, 0);
        if (w) {
            put("mmaptest: writing to the RO mapping (expect a kill)...\n");
            w[0] = 'X';                                  /* -> fatal: read-only */
            put("mmaptest: ERROR — write to RO mapping SUCCEEDED\n");
        }
    }
    /* leave an fd open on purpose: on exit the OS must tear it down on reap (routed to
     * the fs task via KFS_CLOSEALL, not done from the reaper's context) — proves that
     * path survives + doesn't race/leak. */
    (void)sys_open("/tmp/mm", 0);   /* intentionally never closed */

    put("mmaptest: done\n");
}
