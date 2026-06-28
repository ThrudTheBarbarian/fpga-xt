/* /bin/showmotd — opens /etc/motd and prints it, exercising file syscalls. */
#include "usys.h"
void _app_entry(void)
{
    int fd = sys_open("/etc/motd", 0);
    if (fd < 0) {
        static const char e[] = "showmotd: cannot open /etc/motd\n";
        sys_write(1, e, sizeof(e) - 1);
        sys_exit(1);
    }
    char buf[128];
    long n;
    while ((n = sys_read(fd, buf, sizeof buf)) > 0)
        sys_write(1, buf, (unsigned)n);
    sys_close(fd);
    sys_exit(0);
}
