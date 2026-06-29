/* /bin/stackpoke — tries to read ANOTHER process's stack. The stack arena lives at
 * 0x00c0_0000, one 64 KB+guard slot per process. A spawned program runs in a low
 * slot, so slot 7's stack (0x00c7_8000) belongs to a different process and is
 * PL0-none in this space: the read permission-faults and the OS kills us. Without
 * per-process stack isolation it would leak (or worse, be writable). */
#include "usys.h"

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    volatile unsigned *other = (volatile unsigned *)0x00c78000;   /* slot 7's stack */
    sys_write(1, "stackpoke: reading another process's stack @0x00c78000 (expect a kill)...\n", 73);
    unsigned v = *other;                                          /* -> PL0 permission fault */
    (void)v;
    sys_write(1, "stackpoke: LEAK! another stack was readable\n", 44);
}
