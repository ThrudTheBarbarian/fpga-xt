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
