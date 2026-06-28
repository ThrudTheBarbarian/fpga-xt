/* /bin/demandtest — exercise the lazy (demand-zero) heap: malloc 128 KB, touch
 * every page (each first touch faults -> a zero page is mapped on demand and the
 * store re-runs), then verify. The shell builtin reports pages demand-mapped. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    enum { N = 128 * 1024 };
    unsigned char *buf = malloc(N);
    if (!buf) { printf("demandtest: malloc(%d) failed\n", N); return; }
    for (int i = 0; i < N; i++) buf[i] = (unsigned char)(i * 7 + 1);   /* touch every page */
    int ok = 1;
    for (int i = 0; i < N; i++) if (buf[i] != (unsigned char)(i * 7 + 1)) { ok = 0; break; }
    printf("demandtest: wrote+verified %d KB on the lazy heap -> %s\n", N / 1024, ok ? "OK" : "CORRUPT");
    fflush(stdout);
}
