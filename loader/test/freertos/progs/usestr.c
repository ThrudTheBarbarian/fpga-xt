/* /bin/usestr — imports strrev() from libutil.so (resolved by the loader at
 * spawn time via DT_NEEDED). Proves cross-module symbol resolution. */
#include "usys.h"
extern char *strrev(char *);   /* from libutil.so */

void _app_entry(void)
{
    char buf[] = "Hello, shared library!";
    sys_write(1, "usestr: before = ", 17);
    sys_write(1, buf, sizeof(buf) - 1); sys_write(1, "\n", 1);
    strrev(buf);                                   /* cross-module call */
    sys_write(1, "usestr: after  = ", 17);
    sys_write(1, buf, sizeof(buf) - 1); sys_write(1, "\n", 1);
    sys_exit(0);
}
