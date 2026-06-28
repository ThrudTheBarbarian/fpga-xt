/* /bin/libc_test — DT_NEEDED libc.so; exercises malloc/string/printf and now
 * stdio file I/O (fopen/fread over the romfs-backed _open/_read) to prove the
 * filesystem path libc.so (and FreeType) need. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    char *s = malloc(64);
    strcpy(s, "hello from a program, via libc.so");
    printf("libc_test: %s (strlen=%d, malloc=%p)\n", s, (int)strlen(s), (void *)s);
    free(s);

    FILE *f = fopen("/OS/etc/motd", "r");
    if (f) {
        char buf[80];
        size_t k = fread(buf, 1, sizeof buf - 1, f);
        buf[k] = 0;
        for (size_t i = 0; i < k; i++) if (buf[i] == '\n') { buf[i] = 0; break; }
        printf("libc_test: fopen(/OS/etc/motd) read %d bytes, first line: \"%s\"\n", (int)k, buf);
        fclose(f);
    } else {
        printf("libc_test: fopen(/OS/etc/motd) FAILED\n");
    }
    fflush(stdout);
}
