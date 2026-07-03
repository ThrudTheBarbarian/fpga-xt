/* motd.c — /System/bin/motd: print the message of the day (/OS/etc/motd on
 * the SD, or the path given as argv[1]). Bare usys.h — tiny, no libc. */
#include "usys.h"

void _app_entry(int argc, char **argv)
{
    const char *path = (argc > 1) ? argv[1] : "/OS/etc/motd";
    int fd = sys_open(path, 0);
    if (fd < 0) {
        sys_write(2, "motd: cannot open ", 18);
        unsigned n = 0; while (path[n]) n++;
        sys_write(2, path, n);
        sys_write(2, "\n", 1);
        sys_exit(1);
    }
    char buf[256];
    long n;
    while ((n = sys_read(fd, buf, sizeof buf)) > 0) sys_write(1, buf, (unsigned)n);
    sys_close(fd);
    sys_exit(0);
}
