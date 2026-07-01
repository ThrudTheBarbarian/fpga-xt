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

    FILE *f = fopen("/System/etc/motd", "r");
    if (f) {
        char buf[80];
        size_t k = fread(buf, 1, sizeof buf - 1, f);
        buf[k] = 0;
        for (size_t i = 0; i < k; i++) if (buf[i] == '\n') { buf[i] = 0; break; }
        printf("libc_test: fopen(/System/etc/motd) read %d bytes, first line: \"%s\"\n", (int)k, buf);
        fclose(f);
    } else {
        printf("libc_test: fopen(/System/etc/motd) FAILED\n");
    }

    /* Same open, but the PATH lives in a malloc'd (per-process heap) buffer, not a
     * rodata literal. The fs service runs in the kernel's master space; it can only
     * read this path if the OS marshalled it into an identity-reachable control page
     * (fs-pagecache step 3b) — a private-heap VA read straight from master space would
     * resolve to the wrong physical and silently open the wrong file (or fail). */
    char *p = malloc(64);
    strcpy(p, "/System/etc/motd");
    FILE *g = fopen(p, "r");
    if (g) {
        char b[80];
        size_t k = fread(b, 1, sizeof b - 1, g);
        b[k] = 0;
        for (size_t i = 0; i < k; i++) if (b[i] == '\n') { b[i] = 0; break; }
        printf("libc_test: fopen(heap path %p) read %d bytes, first line: \"%s\"\n", (void *)p, (int)k, b);
        fclose(g);
    } else {
        printf("libc_test: fopen(heap path) FAILED\n");
    }
    free(p);

    /* Multi-page read + lseek: stream a >4 KB file (a font) in odd-sized chunks that
     * straddle 4 KB page boundaries, and confirm the total equals the file size found
     * via fseek(END)/ftell. Exercises the page-store loop across page transitions and
     * the logical-cursor lseek — the core of fs-pagecache step 3c. */
    FILE *ff = fopen("/System/Fonts/AovelSansRounded.ttf", "r");
    if (ff) {
        fseek(ff, 0, SEEK_END);
        long fsz = ftell(ff);
        fseek(ff, 0, SEEK_SET);
        char chunk[1000];               /* 1000-byte chunks vs 4096 pages -> boundaries cross mid-chunk */
        long total = 0; size_t r;
        while ((r = fread(chunk, 1, sizeof chunk, ff)) > 0) total += (long)r;
        printf("libc_test: streamed font %ld/%ld bytes -> %s (multi-page read+lseek)\n",
               total, fsz, (fsz > 4096 && total == fsz) ? "OK" : "FAIL");
        fclose(ff);
    } else {
        printf("libc_test: fopen(font) FAILED\n");
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
