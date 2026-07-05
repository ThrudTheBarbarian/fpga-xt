/* XTOS dropbear-port libgen.h shim.
 * Our newlib <string.h> already declares basename() (the GNU form), and the stock
 * newlib <libgen.h> re-declares it (XPG form) -> "conflicting types for __xpg_basename".
 * Shadow it: take dirname (posix_shim provides it) and leave basename to <string.h>. */
#ifndef XTOS_LIBGEN_H
#define XTOS_LIBGEN_H
char *dirname(char *);
#endif
