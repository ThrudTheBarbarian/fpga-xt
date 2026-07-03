/* /bin/regtest — Phase-2 read-path check: open Registry.db through the vendored
 * SQLite + the XTOS VFS and dump the desktopIcons rows.  On qemu the DB is a
 * romfs fixture (/System/test/Registry.db); on HW point it at the SD (/OS/var/registry.db). */
#include "registry.h"
#include "usys.h"
#include <stdio.h>
#include <string.h>

static void put(const char *s) { sys_write(1, s, (unsigned)strlen(s)); }

void _app_entry(int argc, char **argv) {
    const char *db = (argc > 1) ? argv[1] : "/System/test/Registry.db";
    if (registry_open(db) != 0) { put("regtest: open FAILED: "); put(db); put("\n"); return; }

    reg_desktop_icon rows[32];
    int n = registry_desktop_icons(rows, 32);
    char line[256];
    snprintf(line, sizeof line, "regtest: %s -> %d desktop icons\n", db, n);
    put(line);
    for (int i = 0; i < n && i < 32; i++) {
        snprintf(line, sizeof line, "  [%d] (%d,%d) type=%d  '%s'  <- %s\n",
                 i, rows[i].x, rows[i].y, rows[i].type, rows[i].displayName, rows[i].path);
        put(line);
    }

    /* also exercise a windowIcons pattern match */
    char ip[REG_PATH_MAX], dn[REG_NAME_MAX];
    if (registry_match("game.xex", 7 /*File*/, ip, sizeof ip, dn, sizeof dn))
        { snprintf(line, sizeof line, "  match(game.xex,File) -> %s\n", ip); put(line); }
    else put("  match(game.xex,File) -> none\n");

    registry_close();
    put("regtest: done\n");
}
