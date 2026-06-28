/* /bin/vmtest — T2-b per-process-heap proof. malloc from libc (now per-process:
 * private libc data + private heap). Run twice: if each instance's malloc returns
 * the SAME address from a fresh heap, the processes have separate heaps (a shared
 * heap would hand the second run a different, higher address). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
void _app_entry(int argc, char **argv)
{
    const char *tag = argc > 1 ? argv[1] : "?";
    char *p = malloc(64);
    snprintf(p, 64, "owned by %s", tag);
    printf("vmtest[%s]: malloc -> %p  contents=\"%s\"\n", tag, (void *)p, p);
    fflush(stdout);
}
