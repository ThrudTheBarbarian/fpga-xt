/* /bin/libc_test — DT_NEEDED libc.so; exercises malloc/string/printf and now
 * stdio file I/O (fopen/fread over the romfs-backed _open/_read) to prove the
 * filesystem path libc.so (and FreeType) need. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    char *s = malloc(64);
    strcpy(s, "hello from a program, via libc.so");
    printf("libc_test: %s (strlen=%d, malloc=%p)\n", s, (int)strlen(s), (void *)s);
    free(s);

    FILE *f = fopen("/System/bin/hello", "r");
    if (f) {
        unsigned char buf[16];
        size_t k = fread(buf, 1, sizeof buf, f);
        printf("libc_test: fopen(/System/bin/hello) read %d bytes, ELF magic %s\n",
               (int)k, (k >= 4 && buf[0] == 0x7f && buf[1] == 'E') ? "OK" : "WRONG");
        fclose(f);
    } else {
        printf("libc_test: fopen(/System/bin/hello) FAILED\n");
    }

    /* Same open, but the PATH lives in a malloc'd (per-process heap) buffer, not a
     * rodata literal. The fs service runs in the kernel's master space; it can only
     * read this path if the OS marshalled it into an identity-reachable control page
     * (fs-pagecache step 3b) — a private-heap VA read straight from master space would
     * resolve to the wrong physical and silently open the wrong file (or fail). */
    char *p = malloc(64);
    strcpy(p, "/System/bin/hello");
    FILE *g = fopen(p, "r");
    if (g) {
        unsigned char b[16];
        size_t k = fread(b, 1, sizeof b, g);
        printf("libc_test: fopen(heap path %p) read %d bytes, ELF magic %s\n",
               (void *)p, (int)k, (k >= 4 && b[0] == 0x7f && b[1] == 'E') ? "OK" : "WRONG");
        fclose(g);
    } else {
        printf("libc_test: fopen(heap path) FAILED\n");
    }
    free(p);

    /* Multi-page read + lseek: stream a >4 KB file (a font) in odd-sized chunks that
     * straddle 4 KB page boundaries, and confirm the total equals the file size found
     * via fseek(END)/ftell. Exercises the page-store loop across page transitions and
     * the logical-cursor lseek — the core of fs-pagecache step 3c. */
    FILE *ff = fopen("/System/bin/toybox", "r");
    if (ff) {
        fseek(ff, 0, SEEK_END);
        long fsz = ftell(ff);
        fseek(ff, 0, SEEK_SET);
        char chunk[1000];               /* 1000-byte chunks vs 4096 pages -> boundaries cross mid-chunk */
        long total = 0; size_t r;
        while ((r = fread(chunk, 1, sizeof chunk, ff)) > 0) total += (long)r;
        printf("libc_test: streamed big binary %ld/%ld bytes -> %s (multi-page read+lseek)\n",
               total, fsz, (fsz > 4096 && total == fsz) ? "OK" : "FAIL");
        fclose(ff);
    } else {
        printf("libc_test: fopen(/System/bin/toybox) FAILED\n");
    }

    /* Writable /tmp (ramfs) over the page store: create a file, write a multi-page
     * deterministic pattern (crosses 4 KB flush boundaries), close, reopen, read it
     * back, compare byte-for-byte. Exercises open-CREATE, the write loop (RMW/growth),
     * dirty flush-on-evict + on-close, and read-back — fs-pagecache step 3c-2. */
    {
        enum { N = 10000 };                        /* > 2 pages: forces flush-on-evict mid-write */
        unsigned char *wb = malloc(N), *rb = malloc(N);
        for (int i = 0; i < N; i++) wb[i] = (unsigned char)(i * 7 + 3);
        FILE *w = fopen("/tmp/scratch", "w");
        size_t wn = w ? fwrite(wb, 1, N, w) : 0;
        if (w) fclose(w);
        FILE *r = fopen("/tmp/scratch", "r");
        size_t rn = r ? fread(rb, 1, N, r) : 0;
        if (r) fclose(r);
        int ok = (wn == (size_t)N && rn == (size_t)N && memcmp(wb, rb, N) == 0);
        printf("libc_test: /tmp write+readback %d bytes (wrote %u read %u) -> %s (ramfs page store)\n",
               N, (unsigned)wn, (unsigned)rn, ok ? "OK" : "FAIL");
        free(wb); free(rb);
    }

    /* gettimeofday: must return a real, advancing wall clock (A9 global timer),
     * not the old always-zero stub. */
    struct timeval t0, t1;
    int g0 = gettimeofday(&t0, NULL);
    volatile unsigned spin = 0; for (unsigned i = 0; i < 3000000u; i++) spin++;
    int g1 = gettimeofday(&t1, NULL);
    int advanced = (t1.tv_sec > t0.tv_sec) ||
                   (t1.tv_sec == t0.tv_sec && t1.tv_usec > t0.tv_usec);
    printf("libc_test: gettimeofday rc=%d/%d  t0=%ld.%06ld  t1=%ld.%06ld  -> %s\n",
           g0, g1, (long)t0.tv_sec, (long)t0.tv_usec, (long)t1.tv_sec, (long)t1.tv_usec,
           (g0 == 0 && g1 == 0 && advanced) ? "ADVANCING (OK)" : "FAIL");

    fflush(stdout);
}
