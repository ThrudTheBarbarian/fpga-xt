/*
 * sh.c — /System/bin/sh: a Lua interpreter / shell. `sh <script>` runs the script in
 * a fresh lua_State and exits; with no argument it would drop to a REPL (TODO). Each
 * invocation is its own PL0 process, so scripts never share Lua globals.
 *
 * Embeds the real Lua 5.4 core, linked against libc.so/libm.so. spawn("name") launches
 * /System/bin/name (the kernel also resolves /bin/name to the romfs).
 */
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "usys.h"
#include <string.h>

/* spawn(name [, ...args]) -> pid. Bare name resolves to /System/bin/name. */
static int l_spawn(lua_State *L)
{
    const char *name = luaL_checkstring(L, 1);
    char path[80];
    if (name[0] == '/') {
        int k = 0; while (name[k] && k < (int)sizeof path - 1) { path[k] = name[k]; k++; } path[k] = 0;
    } else {
        const char *pre = "/System/bin/"; int k = 0; while (pre[k]) { path[k] = pre[k]; k++; }
        for (int j = 0; name[j] && k < (int)sizeof path - 1; j++) path[k++] = name[j];
        path[k] = 0;
    }
    char *av[1] = { path };
    lua_pushinteger(L, sys_spawn(path, 1, av));
    return 1;
}

static void open_libs(lua_State *L)
{
    static const luaL_Reg libs[] = {
        { LUA_GNAME,       luaopen_base },
        { LUA_TABLIBNAME,  luaopen_table },
        { LUA_STRLIBNAME,  luaopen_string },
        { LUA_MATHLIBNAME, luaopen_math },
        { NULL, NULL }
    };
    for (const luaL_Reg *lib = libs; lib->func; lib++) {
        luaL_requiref(L, lib->name, lib->func, 1);
        lua_pop(L, 1);
    }
}

void _app_entry(int argc, char **argv)
{
    if (argc < 2) { sys_write(2, "sh: usage: sh <script>\n", 23); sys_exit(1); }
    lua_State *L = luaL_newstate();
    if (!L) { sys_write(2, "sh: out of memory\n", 18); sys_exit(1); }
    open_libs(L);
    lua_register(L, "spawn", l_spawn);
    int rc = 0;
    if (luaL_dofile(L, argv[1]) != LUA_OK) {        /* loads via fopen -> VFS -> SD */
        const char *e = lua_tostring(L, -1);
        sys_write(2, "sh: ", 4); sys_write(2, argv[1], strlen(argv[1]));
        sys_write(2, ": ", 2); if (e) sys_write(2, e, strlen(e)); sys_write(2, "\n", 1);
        rc = 1;
    }
    lua_close(L);
    sys_exit(rc);
}
