/* netup.c — /bin/netup: bring up the network stack (SYS_net_up).
 *
 * Run from /boot/20-Networking so the stack starts by explicit boot-script
 * decision, not kernel magic. Idempotent (a second call is a no-op). The
 * bring-up is async: GEM0 + lwIP start now; DHCP/mDNS/SNTP complete in the
 * background as the link comes up. Bare usys (no libc), like sshd.c.
 */
#include "usys.h"

static void klg(const char *s) { int n = 0; while (s[n]) n++; sys_klog(s, (unsigned)n); }

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    __syscall(SYS_net_up, 0, 0, 0);
    /* to dmesg, not the console — init's "Networking [ OK ]" is the user-visible line */
    klg("netup: network stack starting (DHCP/mDNS/SNTP in background)\n");
    sys_exit(0);
}
