/* xexload.c — /bin/xexload: run a standalone Atari executable (.xex / DOS
 * binary) on the fabric 6502 from the command line (mirrors /bin/xlboot).
 *
 *   xexload <file.xex>            load+run on the fidelity core (cycle-exact)
 *   xexload --turbo <file.xex>    load+run on the turbo core (~56x)
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
    int turbo = 0, ai = 1;
    if (ai < argc && (streq(argv[ai], "--turbo") || streq(argv[ai], "-t"))) { turbo = 1; ai++; }
    if (ai >= argc) { puts2(2, "usage: xexload [--turbo] <file.xex>\n"); sys_exit(2); }

    long rc = sys_xexload(argv[ai], turbo);
    if (rc == 0) { puts2(1, "xexload: ok\n"); sys_exit(0); }
    puts2(2, "xexload: failed\n");
    sys_exit(1);
}
