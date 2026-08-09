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
    if (argc < 2) { puts2(2, "usage: xlboot <file.atr> | xlboot -e\n"); sys_exit(2); }

    long rc;
    if (argv[1][0] == '-' && argv[1][1] == 'e')
        rc = sys_xl_boot((const char *)0, 0);         /* eject -> BASIC */
    else
        rc = sys_xl_boot(argv[1], 1);                 /* mount as D1:, coldstart */

    if (rc == 0) { puts2(1, "xlboot: ok\n"); sys_exit(0); }
    puts2(2, "xlboot: failed\n");
    sys_exit(1);
}
