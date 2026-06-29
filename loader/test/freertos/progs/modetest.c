/* /bin/modetest — report the CPU privilege level the program runs at. Reads the
 * CPSR mode field: 0x10 = User (PL0, unprivileged), anything else = privileged.
 * Spawned programs should run at PL0. */
#include "usys.h"

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    unsigned cpsr; __asm__ volatile("mrs %0, cpsr" : "=r"(cpsr));
    if ((cpsr & 0x1f) == 0x10) {
        static const char m[] = "modetest: PL0 (User mode) — unprivileged, protected\n";
        sys_write(1, m, sizeof(m) - 1);
    } else {
        static const char m[] = "modetest: PRIVILEGED (not User mode!)\n";
        sys_write(1, m, sizeof(m) - 1);
    }
}
