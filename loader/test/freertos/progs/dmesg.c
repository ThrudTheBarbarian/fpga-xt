/* dmesg.c — /bin/dmesg: dump the kernel diagnostic log (/proc/kmsg, the live
 * klog ring). Also persisted to /OS/var/log/system.log each boot. Bare usys.
 * -c: print, then CLEAR the ring (a write to /proc/kmsg) — set up a test, clear,
 * run it, and the next dmesg holds only what the test logged. */
#include "usys.h"
void _app_entry(int argc, char **argv)
{
    int clear = (argc > 1 && argv[1][0] == '-' && argv[1][1] == 'c' && !argv[1][2]);
    int fd = sys_open("/proc/kmsg", 0);
    if (fd < 0) { sys_write(2, "dmesg: no /proc/kmsg\n", 21); sys_exit(1); }
    char b[1024]; long n;
    while ((n = sys_read(fd, b, sizeof b)) > 0) sys_write(1, b, (unsigned)n);
    sys_close(fd);
    if (clear) {
        int wfd = sys_open("/proc/kmsg", 1);       /* O_WRONLY: any write clears */
        if (wfd < 0) { sys_write(2, "dmesg: kernel too old for -c\n", 29); sys_exit(1); }
        sys_write(wfd, "c", 1);
        sys_close(wfd);
    }
    sys_exit(0);
}
