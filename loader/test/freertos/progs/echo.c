/* /bin/echo — prints its arguments (proves argv passing from the shell). */
#include "usys.h"
static unsigned slen(const char *s) { unsigned n = 0; while (s[n]) n++; return n; }
void _app_entry(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (i > 1) sys_write(1, " ", 1);
        sys_write(1, argv[i], slen(argv[i]));
    }
    sys_write(1, "\n", 1);
    sys_exit(0);
}
