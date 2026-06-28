/* /bin/wxtest — try to modify our own code. With W^X the text segment is
 * read-only, so the store takes a permission fault (and the OS kills us). */
#include <stdio.h>
void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    printf("wxtest: writing to my own code (text) — expect a W^X fault...\n");
    fflush(stdout);
    volatile unsigned *code = (volatile unsigned *)(void *)_app_entry;
    *code = 0xdeadbeefu;                       /* store into RO text -> fault */
    printf("wxtest: the write SUCCEEDED — W^X is NOT enforced!\n");
}
