/* reboot.c - Restart, halt or powerdown the system.
 *
 * Copyright 2013 Elie De Brauwer <eliedebrauwer@gmail.com>

USE_REBOOT(NEWTOY(reboot, "d:fn", TOYFLAG_SBIN|TOYFLAG_NEEDROOT))
USE_REBOOT(OLDTOY(halt, reboot, TOYFLAG_SBIN|TOYFLAG_NEEDROOT))
USE_REBOOT(OLDTOY(poweroff, reboot, TOYFLAG_SBIN|TOYFLAG_NEEDROOT))

config REBOOT
  bool "reboot"
  default y
  help
    usage: reboot/halt/poweroff [-fn] [-d DELAY]

    Restart, halt, or power off the system.

    -d	Wait DELAY before proceeding (in seconds or m/h/d suffix: -d 1.5m = 90s)
    -f	Force reboot (don't signal init, reboot directly)
    -n	Don't sync filesystems before reboot
*/

#define FOR_reboot
#include "toys.h"
/* XTOS has no <sys/reboot.h>; the constants are all reboot() takes here and
 * they all resolve to the same warm PS reset (SLCR) kernel-side. There is no
 * init to signal for a graceful shutdown, so reboot/halt/poweroff all reset
 * directly (the -f "reboot directly" path is the only path we have). */
#ifndef RB_AUTOBOOT
#define RB_AUTOBOOT    0x01234567
#define RB_HALT_SYSTEM 0xcdef0123
#define RB_POWER_OFF   0x4321fedc
#endif
int reboot(int cmd);

GLOBALS(
  char *d;
)

void reboot_main(void)
{
  struct timespec ts;
  int types[] = {RB_AUTOBOOT, RB_HALT_SYSTEM, RB_POWER_OFF}, idx;

  if (TT.d) {
    xparsetimespec(TT.d, &ts);
    nanosleep(&ts, NULL);
  }

  if (!FLAG(n)) sync();

  idx = stridx("hp", *toys.which->name)+1;
  toys.exitval = reboot(types[idx]);
}
