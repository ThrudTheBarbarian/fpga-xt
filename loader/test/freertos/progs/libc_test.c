/* /bin/libc_test — DT_NEEDED libc.so; uses malloc/strcpy/strlen/printf from the
 * shared libc to prove a loaded program resolves against libc.so. */
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
    fflush(stdout);
}
