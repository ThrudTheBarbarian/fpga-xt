/* /bin/badpoke — tries to read KERNEL memory from userspace. With the PL0/PL1
 * split enforced, the kernel's data is PL0-none, so this read permission-faults
 * and the OS kills the process (the shell survives). If protection were off, it
 * would print the leaked word instead. */
#include "usys.h"

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    volatile unsigned *kdata = (volatile unsigned *)0x00200000;   /* kernel data section */
    sys_write(1, "badpoke: reading kernel memory @0x00200000 (expect a kill)...\n", 61);
    unsigned v = *kdata;                                          /* -> PL0 permission fault */
    char m[40]; int n = 0;
    const char *p = "badpoke: LEAK! read 0x";
    while (p[n]) { m[n] = p[n]; n++; }
    for (int s = 28; s >= 0; s -= 4) m[n++] = "0123456789abcdef"[(v >> s) & 0xf];
    m[n++] = '\n';
    sys_write(1, m, n);                                           /* should never reach here */
}
