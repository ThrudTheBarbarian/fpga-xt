// xtos/lua_test.c — confirm the vendored Lua builds and embeds: open the libs,
// run a script, and call back into C.

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include <stdio.h>

// A tiny native function exposed to Lua as os.note(msg) — a stand-in for the
// real os/gem bindings to come.
static int l_note(lua_State *L) {
    printf("[os.note] %s\n", luaL_checkstring(L, 1));
    return 0;
}

int main(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    lua_getglobal(L, "os");                 // add os.note to the stock os table
    lua_pushcfunction(L, l_note);
    lua_setfield(L, -2, "note");
    lua_pop(L, 1);

    static const char *script =
        "print(_VERSION .. ' embedded in XTOS')\n"
        "print('2 + 2 =', 2 + 2)\n"
        "os.note('boot scripts will run from OS/Boot/*.lua')\n";

    if (luaL_dostring(L, script) != LUA_OK)
        fprintf(stderr, "lua error: %s\n", lua_tostring(L, -1));

    lua_close(L);
    return 0;
}
