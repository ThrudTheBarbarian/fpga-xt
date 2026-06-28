/* /bin/vmtest — T2-b isolation proof. Reads + writes the per-process private
 * window at 0x1FF00000. Run from the shell's `vmtest` builtin, which first writes
 * a sentinel there in the MASTER space: if isolated, this process sees its own
 * (zeroed) private page, not the sentinel, and its write won't touch the master's.
 */
#include <stdio.h>
void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    volatile unsigned *p = (volatile unsigned *)0x1FF00000u;
    unsigned before = *p;
    *p = 0xBB66BB66u;
    printf("vmtest[proc]: priv@0x1FF00000 before=0x%08x (master wrote 0xAA55AA55), "
           "wrote 0xBB66BB66, read back=0x%08x\n", before, *p);
    fflush(stdout);
}
