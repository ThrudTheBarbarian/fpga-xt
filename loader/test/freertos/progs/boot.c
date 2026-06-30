/*
 * boot.c — the /OS/Boot Lua runner (PL0). The kernel spawns this once with the
 * boot-script paths as argv (sorted by NN prefix). Each script runs in its OWN
 * fresh lua_State, so scripts share no globals. The spawn() binding asks the
 * kernel to launch a program; the kernel records the request and runs it (in task
 * context) after we exit — so a script just says e.g.  spawn("desktop").
 *
 * Embeds the real Lua 5.4 core, linked against libc.so/libm.so. A safe subset of
 * the stdlib is opened (base/table/string/math) — no package/dlopen, no os.execute.
 */
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "usys.h"
#include <string.h>

/* spawn(name) -> launch /System/bin/<name> (the kernel also searches /OS/bin). */
static int l_spawn(lua_State *L)
{
    const char *name = luaL_checkstring(L, 1);
    char path[80];
    const char *pre = "/System/bin/";
    int k = 0; while (pre[k]) { path[k] = pre[k]; k++; }
    for (int j = 0; name[j] && k < (int)sizeof path - 1; j++) path[k++] = name[j];
    path[k] = 0;
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

static void run(const char *path)
{
    lua_State *L = luaL_newstate();
    if (!L) { sys_write(2, "[boot] out of memory\n", 21); return; }
    open_libs(L);
    lua_register(L, "spawn", l_spawn);
    if (luaL_dofile(L, path) != LUA_OK) {           /* loads via fopen -> VFS -> SD */
        const char *e = lua_tostring(L, -1);
        sys_write(2, "[boot] ", 7); sys_write(2, path, strlen(path));
        sys_write(2, ": ", 2); if (e) sys_write(2, e, strlen(e)); sys_write(2, "\n", 1);
    }
    lua_close(L);
}

void _app_entry(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) run(argv[i]);    /* argv[0] = /System/bin/boot */
    sys_exit(0);
}
