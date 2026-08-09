/* xexload.c — /bin/xexload: run a standalone Atari executable (.xex / DOS
 * binary) on the fabric 6502 from the command line (mirrors /bin/xlboot).
 *
 *   xexload <file.xex>            load+run on the fidelity core (cycle-exact)
 *   xexload --turbo <file.xex>    load+run on the turbo core (~56x)
 *   xexload --hold  <file.xex>    HALT at an acid800 test's result screen
 *                                 (breakpoint at _testEnd $1D93) instead of
 *                                 letting it soft-reset -- so `6502 status` Y
 *                                 (00 pass / 80 fail) and a screen grab survive.
 *
 * The kernel boots the XL OS with a 1-sector fake disk and then, as the HOST
 * (via the GP0 debug facility), loads the segments straight into 6502 RAM and
 * drives the PC through the program's INIT ($02E2) and RUN ($02E0) vectors --
 * exactly the mechanism the atari800 emulator uses.  Almost no 6502 code runs
 * during the load, so it is immune to the fragile in-6502 loader it replaces. */
#include <stdint.h>
#include "usys.h"

static int  streq(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }
static void puts2(int fd, const char *s) { unsigned n = 0; while (s[n]) n++; sys_write(fd, s, n); }

void _app_entry(int argc, char **argv)
{
    int flags = 0, ai = 1;         /* bit0 = turbo, bit1 = hold */
    for (; ai < argc; ai++) {
        if (streq(argv[ai], "--turbo") || streq(argv[ai], "-t"))     flags |= 1;
        else if (streq(argv[ai], "--hold") || streq(argv[ai], "-h")) flags |= 2;
        else break;
    }
    if (ai >= argc) { puts2(2, "usage: xexload [--turbo] [--hold] <file.xex>\n"); sys_exit(2); }

    long rc = sys_xexload(argv[ai], flags);
    if (rc == 0) { puts2(1, "xexload: ok\n"); sys_exit(0); }
    puts2(2, "xexload: failed\n");
    sys_exit(1);
}
