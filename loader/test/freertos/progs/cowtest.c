/* /bin/cowtest — T2-c copy-on-write proof on a SYNTHETIC shared-RO region.
 *
 * XTOS_COW_VA is mapped shared READ-ONLY at a pristine template page ("COW" then
 * 0x5A...) in every process. We read it (no fault), then WRITE (permission-faults
 * -> the OS makes a PRIVATE copy and remaps it RW), then read back our own value.
 * Run twice (A/B): each sees the pristine template BEFORE its write — proving the
 * write made a private copy and the instances are isolated, not sharing one page.
 */
#include <stdio.h>
#define COW_VA 0x11000000u
void _app_entry(int argc, char **argv)
{
    const char *tag = argc > 1 ? argv[1] : "?";
    volatile unsigned char *p = (volatile unsigned char *)COW_VA;
    printf("cowtest[%s]: before write  p[0..2]=%c%c%c p[16]=0x%02x (pristine template)\n",
           tag, p[0], p[1], p[2], p[16]);
    p[0]  = (unsigned char)tag[0];     /* first write -> COW fault -> private copy */
    p[16] = 0xAA;
    printf("cowtest[%s]: after write   p[0]=%c    p[16]=0x%02x (own private copy)\n",
           tag, p[0], p[16]);
    fflush(stdout);
}
