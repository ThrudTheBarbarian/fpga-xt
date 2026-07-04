/* dmesg.c — /bin/dmesg: dump the kernel diagnostic log (/proc/kmsg, the live
 * klog ring). Also persisted to /OS/var/log/system.log each boot. Bare usys. */
#include "usys.h"
void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    int fd = sys_open("/proc/kmsg", 0);
    if (fd < 0) { sys_write(2, "dmesg: no /proc/kmsg\n", 21); sys_exit(1); }
    char b[1024]; long n;
    while ((n = sys_read(fd, b, sizeof b)) > 0) sys_write(1, b, (unsigned)n);
    sys_close(fd);
    sys_exit(0);
}
