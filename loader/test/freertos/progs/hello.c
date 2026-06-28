/* /bin/hello — loaded from the romfs, spawned by path. */
#include "usys.h"
static const char m[] = "hello from /bin/hello (loaded from the filesystem)\n";
void _app_entry(void) { sys_write(1, m, sizeof(m) - 1); sys_exit(0); }
