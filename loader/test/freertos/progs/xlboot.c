/* xlboot.c — /bin/xlboot: launch an Atari 8-bit disk image on the fabric 6502
 * from the command line (the desktop double-click path, as a CLI — for scripting
 * and for debugging coldstart with /bin/6502).
 *
 *   xlboot <file.atr>     cold-boot the patched XL OS with the ATR mounted as D1:
 *   xlboot -e             eject: cold-boot to BASIC (no media)
 *
 * Arm `6502 breakreset on` first to freeze the launched OS at its reset vector. */
#include <stdint.h>
#include "usys.h"

static void puts2(int fd, const char *s) { unsigned n = 0; while (s[n]) n++; sys_write(fd, s, n); }

void _app_entry(int argc, char **argv)
{
    if (argc < 2) {
        puts2(2, "usage: xlboot [-a] <file.atr> | xlboot -e\n"
                 "  -a  authentic drive TIMING (a real 1050: ~130 ms/sector).\n"
                 "      Needed by titles whose intro is paced by the drive -- an\n"
                 "      intro that animates from the VBI while sectors stream gets\n"
                 "      its animation budget from how long each SIO call takes.\n"
                 "      Off by default: it also means authentic LOAD times.\n");
        sys_exit(2);
    }

    int argi = 1, authentic = 0;
    if (argv[argi][0] == '-' && argv[argi][1] == 'a') { authentic = 1; argi++; }
    if (argi >= argc) { puts2(2, "xlboot: no image\n"); sys_exit(2); }

    /* Set the timing BEFORE the mount so the very first sector is paced too. */
    sys_sio_timing(authentic ? 19200u : 0u, authentic ? 27000u : 0u);

    long rc;
    if (argv[argi][0] == '-' && argv[argi][1] == 'e')
        rc = sys_xl_boot((const char *)0, 0);         /* eject -> BASIC */
    else
        rc = sys_xl_boot(argv[argi], 1);              /* mount as D1:, coldstart */

    if (rc == 0) { puts2(1, "xlboot: ok\n"); sys_exit(0); }
    puts2(2, "xlboot: failed\n");
    sys_exit(1);
}
